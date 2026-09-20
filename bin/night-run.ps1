<#
    night-run.ps1 - unattended task runner for overnight code work.

    ONE TASK PER MODEL CALL, FRESH CONTEXT EACH TIME.
    That is the whole trick. A single long-running prompt always dies: context
    fills, errors compound, and nothing verifies the result. This loop instead:
        pick one task -> run it in a clean session -> run the tests
        -> green: git commit and mark [x]
        -> red:   git reset --hard and mark [!] BLOCKED, then move on
    So a task that goes wrong costs you one task, not the whole night.

    EXECUTORS - who actually writes the code
        claude    Claude Code headless (claude -p). Uses the subscription you
                  already pay for, so it adds no cost, and it is by far the
                  strongest option. Bounded by your 5-hour / weekly usage
                  windows.
        opencode  opencode against any provider in opencode.json:
                  google/gemini-3.5-flash-lite
                                      DEFAULT FREE TIER. 1000 requests/day,
                                      15/min, 1M context, tool calling. Needs
                                      GEMINI_API_KEY - free from
                                      https://aistudio.google.com/apikey with
                                      no credit card. google/gemini-3.5-flash
                                      is stronger but only 250/day.
                  openrouter/<model>  50 requests/day, or 1000/day once you
                                      have ever bought $10 of credit.
                                      Needs OPENROUTER_API_KEY.
                  local/gpt-oss-20b   llama.cpp on this machine. The local
                                      stack was REMOVED on 2026-09-14 to
                                      reclaim disk; rebuild it with
                                      bin\install-llamacpp.ps1 plus a model
                                      download if you ever want it back.

    NOT AVAILABLE: the Gemini CLI (`gemini`) executor was removed on
    2026-09-20. Google retired "Gemini Code Assist for individuals" on
    2026-06-18, so its free Sign-in-with-Google path now fails outright with
    "This client is no longer supported". Google's replacement is the
    Antigravity CLI (`agy`, https://antigravity.google) - free tier, OAuth,
    no key - but it is a separate install that is not verified on this
    machine. The Gemini MODELS are still reachable and still free through
    opencode above; only that one CLI's login died.
        auto      DEFAULT. Works down a CHAIN, moving to the next executor
                  whenever the current one reports a usage limit:

                      claude  ->  opencode

                  The subscription does as much as it can, then Gemini's free
                  1000/day finishes the queue. Neither is billed. The night
                  stops only when the whole chain is exhausted.

    USAGE
        .\night-run.ps1 -Root "D:\work\my-project"
        .\night-run.ps1 -Root "D:\work\my-project" -Executor claude -ClaudeModel opus
        .\night-run.ps1 -Root "D:\work\my-project" -Executor opencode   # free Gemini
        .\night-run.ps1 -Root "D:\work\my-project" -DryRun     # plan only, no model, no writes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [ValidateSet("auto","claude","opencode")]
    [string]$Executor         = "auto",
    [string]$ClaudeModel      = "sonnet",
    [ValidateSet("acceptEdits","bypassPermissions")]
    [string]$ClaudePermission = "acceptEdits",
    [string]$OpenCodeModel    = "google/gemini-3.5-flash-lite",
    [string]$TestCmd          = "",                 # auto-detected when empty
    [string]$ServerUrl        = "http://127.0.0.1:8080",
    [int]   $TaskTimeoutMin   = 20,
    [int]   $MaxRetries       = 1,
    [switch]$NoCommit,
    [switch]$AllowTestEdits,
    [switch]$SkipBaseline,      # do not verify the test command before starting
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------- helpers ---
function Write-Log {
    param([string]$Msg, [string]$Color = "Gray")
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Msg
    Write-Host $line -ForegroundColor $Color
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding utf8 }
}

# Always write UTF-8 WITHOUT a BOM. Set-Content -Encoding utf8 on PS 5.1 adds
# one, which drops a stray marker into the user's TASKS.md on every rewrite.
function Write-Lines {
    param([string]$Path, [string[]]$Lines)
    [IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding $false))
}

# Every git call goes through here. Two PowerShell 5.1 traps make the naive
# `& git ... 2>$null` form unsafe for an 8-hour unattended run:
#
#  1. Redirecting a native command's stderr wraps each line in a
#     NativeCommandError record. Under $ErrorActionPreference = "Stop" that
#     THROWS, so a harmless git warning kills the whole night.
#  2. $LASTEXITCODE is the only honest success signal for a native exe.
#
# Returns the exit code and the combined output, and never throws on its own.
function Invoke-Git {
    param([string]$Dir, [string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & git -C $Dir @GitArgs 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{
            Code   = $LASTEXITCODE
            Output = ($out -join "`n")
            Lines  = @($out)
        }
    } finally { $ErrorActionPreference = $prev }
}

# Find the real executable behind a command name.
#
# Get-Command WITHOUT -All returns whatever shadows the name first, and in a
# shell with a user profile loaded that is often a FUNCTION or an ALIAS - whose
# .Source is the empty string. Split-Path then dies with "Cannot bind argument
# to parameter 'Path' because it is an empty string", which is what a real run
# hit: `claude` is a function in this machine's PowerShell profile, so the
# runner worked under -NoProfile and crashed in a normal shell.
#
# So: ask for ALL candidates and keep only ones that are actually on disk.
function Resolve-CliTarget {
    param([string]$Name, [string[]]$PreferNames)

    $cands = @(Get-Command $Name -All -ErrorAction SilentlyContinue |
               Where-Object { $_.Source })      # drops functions and aliases

    # 1. a real executable we can hand to Start-Process
    $app = $cands |
           Where-Object { $_.CommandType -eq 'Application' -and $_.Source -match '\.(exe|cmd|bat)$' } |
           Select-Object -First 1
    if ($app) { return $app.Source }

    # 2. a .ps1 shim - Start-Process cannot launch one, so take its sibling
    $ps1 = $cands | Where-Object { $_.CommandType -eq 'ExternalScript' } | Select-Object -First 1
    if ($ps1) {
        $dir = Split-Path $ps1.Source -Parent
        foreach ($n in $PreferNames) {
            $c = Join-Path $dir $n
            if (Test-Path $c) { return $c }
        }
    }

    # 3. last resort: walk PATH ourselves
    foreach ($d in ($env:PATH -split ';')) {
        if (-not $d) { continue }
        foreach ($n in $PreferNames) {
            try {
                $c = Join-Path $d $n
                if (Test-Path $c) { return $c }
            } catch { }   # a malformed PATH entry must not kill the run
        }
    }
    return $null
}

function Resolve-OpenCodeExe {
    # Prefer the bundled .exe: a .cmd would route through cmd.exe, and while the
    # prompt now travels on stdin, a real exe keeps the remaining argv clean.
    $cands = @(Get-Command opencode -All -ErrorAction SilentlyContinue | Where-Object { $_.Source })
    foreach ($c in $cands) {
        $dir = Split-Path $c.Source -Parent
        $exe = Join-Path $dir "node_modules\opencode-ai\bin\opencode.exe"
        if (Test-Path $exe) { return $exe }
    }
    $found = Resolve-CliTarget -Name "opencode" -PreferNames @("opencode.exe", "opencode.cmd")
    if ($found) { return $found }
    throw "Could not find an opencode executable. Run: npm install -g opencode-ai"
}

function Resolve-ClaudeExe {
    $found = Resolve-CliTarget -Name "claude" -PreferNames @("claude.exe", "claude.cmd")
    if ($found) { return $found }
    throw "Could not find a claude executable on PATH. Is Claude Code installed?"
}

# Returns the first test file the task modified, or $null.
#
# WHY THIS EXISTS - observed, not hypothetical:
# Given "add div(a,b) and assert div(1,0) === 42", the model wrote
#     function div(a, b) { return 42; }
# and edited the test to match. Tests went green and it was committed.
# A test gate only proves the tests pass. If a task may edit the test AND the
# implementation, it can always make them agree. So the gate must be immutable
# for the task being graded by it.
function Get-TouchedTestFile {
    param([string]$Dir)
    $patterns = @(
        '(^|/)tests?/', '(^|/)spec/', '\.test\.', '\.spec\.',
        '_test\.', 'Test\.php$', 'Tests\.php$', '_test\.dart$', '(^|/)test\.js$'
    )
    foreach ($line in (Invoke-Git -Dir $Dir -GitArgs @("status", "--porcelain")).Lines) {
        $f = ($line.Substring(2)).Trim() -replace '\\', '/' -replace '^"|"$', ''
        foreach ($p in $patterns) { if ($f -match $p) { return $f } }
    }
    return $null
}

# Returns every queued task as { Text; LineNumber }, in file order, SKIPPING
# anything inside an HTML comment.
#
# WHY: the TASKS.md templates document how to size a task by showing examples -
#   <!--  WRONG - too big:
#           - [ ] Build the products module
#           - [ ] Add authentication  -->
# A plain regex scan treats those as real work. Copy the shipped template into
# a project, run the night, and the runner faithfully starts with "queued <-
# the runner picks the first of these", then "Build the products module": the
# exact vague tasks the template exists to warn you against. Comments are the
# natural place to put examples, so the scanner has to understand them.
function Get-QueuedTasks {
    param([string]$Path)
    $lines     = [IO.File]::ReadAllLines($Path)
    $out       = @()
    $inComment = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        # Rebuild the line from only the parts OUTSIDE <!-- --> spans, so an
        # inline comment can neither hide a real task nor reveal a fake one.
        $visible = ""
        $rest    = $lines[$i]
        while ($true) {
            if ($inComment) {
                $close = $rest.IndexOf("-->")
                if ($close -lt 0) { break }
                $rest      = $rest.Substring($close + 3)
                $inComment = $false
            } else {
                $open = $rest.IndexOf("<!--")
                if ($open -lt 0) { $visible += $rest; break }
                $visible  += $rest.Substring(0, $open)
                $rest      = $rest.Substring($open + 4)
                $inComment = $true
            }
        }
        if ($visible -match '^\s*-\s*\[ \]\s+(.+)$') {
            $out += [pscustomobject]@{ Text = $Matches[1].Trim(); LineNumber = $i + 1 }
        }
    }
    return $out
}

function Get-TestCommand {
    param([string]$Dir)
    if (Test-Path (Join-Path $Dir "artisan"))      { return "php artisan test" }
    if (Test-Path (Join-Path $Dir "pubspec.yaml")) { return "flutter test" }
    if (Test-Path (Join-Path $Dir "package.json")) {
        try {
            $pkg = Get-Content (Join-Path $Dir "package.json") -Raw | ConvertFrom-Json
            if ($pkg.scripts -and $pkg.scripts.test) { return "npm test" }
        } catch { }
    }
    if (Test-Path (Join-Path $Dir "pyproject.toml")) { return "pytest -q" }
    return ""
}

# Did the executor stop because we ran out of quota, rather than because the
# task was hard? Only consulted on a NON-ZERO exit, so a task that legitimately
# writes the words "rate limit" into a source file cannot trip it.
function Test-UsageLimited {
    param([string]$LogPath)
    if (-not (Test-Path $LogPath)) { return $false }
    $t = Get-Content $LogPath -Raw -ErrorAction SilentlyContinue
    if (-not $t) { return $false }
    return $t -match '(?i)usage limit reached|rate limit|too many requests|\b429\b|quota exceeded|insufficient credits'
}

# Runs a native command with a hard timeout. Returns its exit code, or -1 on timeout.
# Start-Process is used deliberately: in PowerShell 5.1, piping a native command
# with 2>&1 wraps stderr in NativeCommandError records and corrupts $LASTEXITCODE.
function Invoke-WithTimeout {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkDir,
          [int]$TimeoutSec, [string]$OutFile, [string]$StdinFile)

    $errFile = "$OutFile.err"
    $sp = @{
        FilePath               = $FilePath
        ArgumentList           = $Arguments
        WorkingDirectory       = $WorkDir
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $OutFile
        RedirectStandardError  = $errFile
    }
    # The prompt goes in on stdin, never as an argument. claude.cmd routes
    # through cmd.exe, which would mangle a multi-line prompt containing
    # & | ^ or %. A redirected file has no quoting rules at all.
    if ($StdinFile) { $sp.RedirectStandardInput = $StdinFile }

    $p = Start-Process @sp

    # MUST cache the process handle before the process exits, otherwise
    # $p.ExitCode is silently $null and every task looks like a failure.
    # This is a real PowerShell trap, not defensive noise:
    #   Start-Process -PassThru, no .Handle read -> $p.ExitCode = ''
    #   Start-Process -PassThru, .Handle cached  -> $p.ExitCode = 0
    $null = $p.Handle

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        Write-Log "  TIMEOUT after $TimeoutSec s - killing process tree" "Red"
        try { taskkill /PID $p.Id /T /F | Out-Null } catch { }
        # Fold stderr in even on the timeout path, or the log loses the reason.
        if (Test-Path $errFile) {
            $e = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
            if ($e) { Add-Content -Path $OutFile -Value $e -Encoding utf8 }
            Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        }
        return -1
    }
    if (Test-Path $errFile) {
        $e = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        if ($e) { Add-Content -Path $OutFile -Value $e -Encoding utf8 }
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    $code = $p.ExitCode
    if ($null -eq $code) {
        # Should be unreachable now that .Handle is cached. If it ever fires,
        # it is a runner bug - do not silently blame the task for it.
        throw "Could not read exit code for '$FilePath'. This is a night-run bug, not a task failure."
    }
    return $code
}

# Builds the command line for whichever executor is currently active.
function Get-ExecutorInvocation {
    param([string]$Kind, [string]$PromptFile)
    if ($Kind -eq "claude") {
        return @{
            File  = $script:ClaudeExe
            Args  = @("-p", "--model", $ClaudeModel,
                      "--permission-mode", $ClaudePermission,
                      "--output-format", "text")
            Stdin = $PromptFile          # prompt arrives on stdin, not argv
            Label = "claude/$ClaudeModel"
        }
    }
    # The prompt goes in on stdin here too, NOT as argv. Being a real .exe is
    # not enough: PowerShell 5.1 does not escape double quotes inside a native
    # argument, so a task line like
    #     ... so 1234.5 becomes "1,234.50" and -9.005 becomes "-9.01"
    # splits at the quotes and opencode's parser reads the "-9.01" fragment as
    # an unknown flag, prints its help and exits 1. Every task carrying a
    # quoted example - which is exactly how a task should be written - failed.
    return @{
        File  = $script:OpenCodeExe
        Args  = @("run", "--auto", "--model", $OpenCodeModel)
        Stdin = $PromptFile
        Label = "opencode/$OpenCodeModel"
    }
}

# ------------------------------------------------------------- preflight ---
if (-not (Test-Path $Root)) { throw "Root not found: $Root" }
$Root      = (Resolve-Path $Root).Path
$TasksFile = Join-Path $Root "TASKS.md"
$AgentDir  = Join-Path $Root ".agent"
if (-not (Test-Path $TasksFile)) {
    throw "No TASKS.md in $Root. Copy the template from D:\ai\workflow\templates\."
}

# --- git checks run BEFORE .agent/ exists -----------------------------------
# Order matters. If we created .agent/ first, git status would report it as
# untracked and the dirty check below would always fail. And because the loop
# runs `git add -A`, an un-excluded .agent/ would commit its own logs into
# the repo on every task.
if ((Invoke-Git -Dir $Root -GitArgs @("rev-parse", "--is-inside-work-tree")).Code -ne 0) {
    throw "$Root is not a git repository. Run git init and make one commit first - rollback depends on it."
}

# Ask git where its dir actually is - inside a worktree, .git is a FILE.
$gitDir = (Invoke-Git -Dir $Root -GitArgs @("rev-parse", "--git-dir")).Output.Trim()
if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $Root $gitDir }

# .git/info/exclude is local and untracked, so writing here cannot dirty the
# tree. CREATE it when missing: if this step silently does nothing, .agent/
# stays visible to git and `git add -A` commits the night's logs into the repo.
$infoDir     = Join-Path $gitDir "info"
$excludeFile = Join-Path $infoDir "exclude"
if (-not (Test-Path $infoDir)) { New-Item -ItemType Directory -Force -Path $infoDir | Out-Null }
$ex = if (Test-Path $excludeFile) { Get-Content $excludeFile -Raw -ErrorAction SilentlyContinue } else { "" }
if ($ex -notmatch '(?m)^\.agent/\s*$') {
    Add-Content -Path $excludeFile -Value "`n.agent/" -Encoding utf8
}

$dirty = (Invoke-Git -Dir $Root -GitArgs @("status", "--porcelain")).Lines
if ($dirty) {
    throw "Working tree is dirty. Commit or stash first, otherwise a rollback will destroy your own changes.`n$($dirty -join "`n")"
}

New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null

$stamp          = Get-Date -Format "yyyyMMdd-HHmm"
$script:LogFile = Join-Path $AgentDir "night-$stamp.log"

# Single-instance lock, so two runners cannot fight over one working tree.
#
# The lock records the OWNING PROCESS ID, not just a timestamp. A lock file
# alone cannot tell "a run is in progress" from "a run was killed": Ctrl+C, a
# closed terminal or a truncated pipeline all skip the finally block and leave
# the file behind. That used to mean the next night refused to start and the
# queue sat untouched until someone deleted the file by hand - the opposite of
# what an unattended runner is for. So an orphaned lock is now detected and
# reclaimed; only a lock whose process is genuinely alive blocks the run.
$lock = Join-Path $AgentDir "night-run.lock"
if (Test-Path $lock) {
    $raw     = (Get-Content $lock -Raw -ErrorAction SilentlyContinue).Trim()
    $ownerPid = $null
    # \s* on both sides: Set-Content writes CRLF, and a bare $ will not match
    # with the \r still sitting there - which silently made every stale lock
    # look unparseable, and so un-reclaimable.
    if ($raw -match '(?m)^\s*pid=(\d+)\s*$') { $ownerPid = [int]$Matches[1] }

    $alive = $false
    if ($ownerPid) {
        $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
        # A recycled PID belonging to some unrelated program must not look like
        # a live runner, so the name has to match too.
        if ($proc -and $proc.ProcessName -match '(?i)powershell|pwsh') { $alive = $true }
    } else {
        # A lock from an older version has no pid line. Refuse, as before:
        # guessing "it is probably stale" could start a second runner.
        $alive = $true
    }

    if ($alive) {
        throw "A night-run is already active (lock: $lock, owner pid $ownerPid). If you are sure it is dead, delete the lock."
    }
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    $script:StaleLockPid = $ownerPid
}
Write-Lines -Path $lock -Lines @(
    "pid=$PID"
    "started=$(Get-Date -Format 's')"
    "root=$Root"
)

try {
    Write-Log "=== NIGHT RUN START ===" "Cyan"
    Write-Log "root    : $Root"
    if ($script:StaleLockPid) {
        Write-Log "lock    : cleared a stale lock from dead pid $($script:StaleLockPid)" "Yellow"
    }

    if (-not $TestCmd) { $TestCmd = Get-TestCommand -Dir $Root }
    if (-not $TestCmd) {
        Write-Log "WARNING: no test command detected. Tasks will be committed UNVERIFIED." "Yellow"
    } else {
        Write-Log "tests   : $TestCmd"
    }

    if ($NoCommit) {
        # Without commits there is no safe point to reset to, so rollback is off
        # as well - otherwise the first failure would wipe every earlier task.
        Write-Log "WARNING: -NoCommit is set. Nothing is committed AND nothing is" "Yellow"
        Write-Log "         rolled back, so a failed task leaves its mess behind." "Yellow"
        Write-Log "         Use this to try the runner out, never for a real night." "Yellow"
    }

    # --- executor chain -----------------------------------------------------
    # auto walks down the chain, dropping to the next one each time the current
    # executor reports a usage limit. Anything else is a chain of one.
    $script:Chain = if ($Executor -eq "auto") { @("claude","opencode") } else { @($Executor) }

    # Resolve every executable up front, so a broken PATH is a preflight error
    # at 22:00 rather than a surprise at 03:00 when the chain drops to it.
    # A fallback that will not resolve is dropped with a warning; only a broken
    # ACTIVE executor is fatal.
    $resolved = @()
    foreach ($e in $script:Chain) {
        try {
            switch ($e) {
                "claude" {
                    $script:ClaudeExe = Resolve-ClaudeExe
                    Write-Log "claude  : $($script:ClaudeExe) (model $ClaudeModel, $ClaudePermission)"
                }
                "opencode" {
                    $script:OpenCodeExe = Resolve-OpenCodeExe
                    Write-Log "opencode: $($script:OpenCodeExe) (model $OpenCodeModel)"
                }
            }
            $resolved += $e
        } catch {
            if ($e -eq $script:Chain[0]) { throw }
            Write-Log "NOTE   : dropping '$e' from the chain - $($_.Exception.Message)" "Yellow"
        }
    }
    $script:Chain = $resolved

    # Backend credentials. Same rule for every executor: HARD FAIL when it is
    # the ACTIVE one, WARN and drop it when it is only further down the chain,
    # because a missing fallback costs you the tail of the night, not the night.
    $keep = @()
    foreach ($e in $script:Chain) {
        $problem = $null

        if ($e -eq "opencode") {
            if ($OpenCodeModel -like "local/*") {
                # The local stack was removed on 2026-09-14. This branch survives
                # so that rebuilding it (bin\install-llamacpp.ps1) just works.
                $healthy = $false
                try {
                    $h = Invoke-RestMethod "$ServerUrl/health" -TimeoutSec 10
                    $healthy = ($h.status -eq "ok")
                } catch { $healthy = $false }
                if ($healthy) { Write-Log "backend : llama-server ok at $ServerUrl" }
                else { $problem = "llama-server is not healthy at $ServerUrl. Start it with: D:\ai\bin\start-server.ps1" }
            }
            elseif ($OpenCodeModel -like "google/*") {
                # opencode accepts any of these three for the google provider.
                $names = @("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY")
                $found = $null
                foreach ($n in $names) {
                    if ([Environment]::GetEnvironmentVariable($n, "User") -or
                        [Environment]::GetEnvironmentVariable($n, "Process")) { $found = $n; break }
                }
                if ($found) { Write-Log "backend : $found is set (google provider)" }
                else {
                    $problem = "No Gemini API key found. Get one FREE - no credit card:`n" +
                               "  1. open https://aistudio.google.com/apikey`n" +
                               "  2. sign in and click 'Create API key'`n" +
                               "  3. run, then open a NEW shell:`n" +
                               "     [Environment]::SetEnvironmentVariable('GEMINI_API_KEY','<paste>','User')`n" +
                               "gemini-3.5-flash-lite is then 1000 requests/day at no cost."
                }
            }
            elseif ($OpenCodeModel -like "openrouter/*") {
                if ([Environment]::GetEnvironmentVariable("OPENROUTER_API_KEY", "User") -or $env:OPENROUTER_API_KEY) {
                    Write-Log "backend : OPENROUTER_API_KEY is set"
                } else {
                    $problem = "OPENROUTER_API_KEY is not set. Set it with:`n" +
                               "  [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY','sk-or-...','User')`n" +
                               "then open a NEW shell so it is visible."
                }
            }
        }

        if (-not $problem) { $keep += $e; continue }

        if ($e -eq $script:Chain[0]) {
            throw $problem
        }
        Write-Log "NOTE   : dropping '$e' from the chain." "Yellow"
        foreach ($l in ($problem -split "`n")) { Write-Log "         $l" "Yellow" }
    }
    $script:Chain  = $keep
    $script:Active = $script:Chain[0]

    $rest = @($script:Chain | Select-Object -Skip 1)
    if ($rest.Count) {
        Write-Log "executor: $($script:Active)  (then: $($rest -join ' -> '))"
    } else {
        Write-Log "executor: $($script:Active)  (no fallback - the night stops when this one is exhausted)" "Yellow"
    }

    # --- baseline: does the test command pass BEFORE any task runs? ---------
    #
    # Every task is graded by this command, so if it fails on a clean tree it
    # will fail after task 1, task 2 and task 50 as well - and each will be
    # rolled back and marked [!] as though the model wrote bad code. A whole
    # queue can be burned that way on a missing vendor/ directory or a database
    # that is not configured for tests.
    #
    # Observed, not hypothetical: a Laravel project with no vendor/ and the
    # sqlite lines still commented out in phpunit.xml. The agent wrote a
    # perfectly good test, then spent the task running composer install trying
    # to make the gate work.
    #
    # So: run it once, here, and refuse to start if it is already red.
    if ($TestCmd -and -not $SkipBaseline) {
        Write-Log "baseline: running '$TestCmd' once to check the gate works..."
        $baseOut = Join-Path $AgentDir ("baseline-{0}.log" -f $stamp)
        $brc = Invoke-WithTimeout -FilePath "cmd.exe" -Arguments @("/c", $TestCmd) `
                   -WorkDir $Root -TimeoutSec 900 -OutFile $baseOut

        if ($brc -eq 0) {
            Write-Log "baseline: tests pass on a clean tree" "Green"
        } else {
            $tail = ""
            if (Test-Path $baseOut) {
                $tail = (Get-Content $baseOut -Tail 15 -ErrorAction SilentlyContinue) -join "`n"
            }
            Write-Log "baseline: FAILED (exit $brc)" "Red"
            throw @"
The test command fails on a CLEAN tree, before any task has run.

    command : $TestCmd
    output  : $baseOut

Every task is graded by this command, so starting now would mark the whole
queue [!] for a reason that has nothing to do with the model. Fix the
environment first. Common causes:

  * dependencies not installed      composer install   /   npm install
  * no test database configured     for Laravel, uncomment the sqlite lines
                                    in phpunit.xml:
                                      <env name="DB_CONNECTION" value="sqlite"/>
                                      <env name="DB_DATABASE" value=":memory:"/>
  * a test suite that was already red before you got here

Last lines of the output:
$tail

Pass -SkipBaseline to start anyway.
"@
        }
    }

    if ($DryRun) {
        Write-Log "--- DRY RUN: queued tasks ---" "Cyan"
        $queued = @(Get-QueuedTasks -Path $TasksFile)
        foreach ($q in $queued) { Write-Log ("  {0,4}. {1}" -f $q.LineNumber, $q.Text) }
        Write-Log "--- $($queued.Count) task(s), no model calls, no writes ---" "Cyan"
        return
    }

    # ----------------------------------------------------------- main loop ---
    $done = 0; $blocked = 0; $t0 = Get-Date

    while ($true) {
        $next = @(Get-QueuedTasks -Path $TasksFile) | Select-Object -First 1
        if (-not $next) { Write-Log "=== QUEUE EMPTY ===" "Cyan"; break }

        $task   = $next.Text
        $lineNo = $next.LineNumber         # 1-based; used to edit the exact line
        Write-Log ""
        Write-Log "TASK: $task" "Cyan"

        $base = (Invoke-Git -Dir $Root -GitArgs @("rev-parse", "HEAD")).Output.Trim()
        $ok   = $false

        $n           = $done + $blocked + 1
        $attempt     = 0
        $maxAttempts = $MaxRetries + 1

        while ($attempt -lt $maxAttempts) {
            $attempt++

            # ROLL BACK BEFORE RETRYING. Without this a retry starts on top of
            # the previous attempt's half-finished edits - and if attempt 1 was
            # rejected for touching a test file, that file is STILL modified, so
            # every retry is rejected for the same reason and can never pass.
            if ($attempt -gt 1) {
                Write-Log "  attempt $attempt of $maxAttempts - resetting to $($base.Substring(0,7)) first" "Yellow"
                $null = Invoke-Git -Dir $Root -GitArgs @("reset", "--hard", $base)
                $null = Invoke-Git -Dir $Root -GitArgs @("clean", "-fd")
            }

            # The prompt is deliberately SHORT and STABLE across tasks:
            # llama-server caches the common prefix, so identical wording is
            # genuinely faster. The real rules live in AGENTS.md, which both
            # opencode and Claude Code load on their own.
            $prompt = "Task: $task`n`n" +
                      "Follow AGENTS.md exactly.`n" +
                      "Change only what this task requires. Do not refactor or tidy anything else.`n" +
                      "When the task is done, stop. Do not start another task."

            $outFile    = Join-Path $AgentDir ("task-{0}-{1:d3}.log" -f $stamp, $n)
            $promptFile = Join-Path $AgentDir ("task-{0}-{1:d3}.prompt" -f $stamp, $n)
            [IO.File]::WriteAllText($promptFile, $prompt, (New-Object System.Text.UTF8Encoding $false))

            $inv = Get-ExecutorInvocation -Kind $script:Active -PromptFile $promptFile
            Write-Log "  running on $($inv.Label)"

            $rc = Invoke-WithTimeout -FilePath $inv.File -Arguments $inv.Args `
                     -WorkDir $Root -TimeoutSec ($TaskTimeoutMin * 60) `
                     -OutFile $outFile -StdinFile $inv.Stdin

            if ($rc -ne 0) {
                Write-Log "  $($script:Active) exited $rc -> $outFile" "Yellow"

                # Out of quota, not out of ability. Switch executors and give
                # the new one a full retry budget - this attempt does not count
                # against the task, because the task was never really tried.
                if ($script:Chain.Count -gt 1 -and (Test-UsageLimited -LogPath $outFile)) {
                    $spent = $script:Active
                    $script:Chain  = @($script:Chain | Select-Object -Skip 1)
                    $script:Active = $script:Chain[0]
                    Write-Log "  USAGE LIMIT on $spent. Switching to $($script:Active) for the rest of the night." "Magenta"
                    $maxAttempts   = $attempt + $MaxRetries + 1
                }
                continue
            }

            # Did it actually do anything? An executor that reads files, decides
            # the work is already done and exits 0 would otherwise sail through
            # the test gate on the suite's existing green and be marked [x] with
            # no commit behind it.
            # TASKS.md is excluded: it is the runner's own bookkeeping, and an
            # executor that ticks its own box must not thereby look productive.
            $changed = @((Invoke-Git -Dir $Root -GitArgs @("status", "--porcelain")).Lines |
                         Where-Object { $_ -notmatch '(?i)[/\\ ]TASKS\.md"?$' })
            if (-not $changed) {
                Write-Log "  NO CHANGES - the executor edited nothing. Not a pass." "Yellow"
                continue
            }

            # The task may not edit the tests that grade it. Tag a task with
            # [test] when writing tests IS the task, or pass -AllowTestEdits.
            if (-not $AllowTestEdits -and $task -notmatch '\[test\]') {
                $touched = Get-TouchedTestFile -Dir $Root
                if ($touched) {
                    Write-Log "  REJECTED: task modified a test file ($touched)." "Red"
                    Write-Log "  A task may not edit the tests that grade it - that is how a model" "Red"
                    Write-Log "  fakes a pass. Split it: one [test] task, then the implementation." "Red"
                    continue
                }
            }

            if (-not $TestCmd) { $ok = $true; break }

            $testOut = "$outFile.tests"
            $trc = Invoke-WithTimeout -FilePath "cmd.exe" -Arguments @("/c", $TestCmd) `
                       -WorkDir $Root -TimeoutSec 900 -OutFile $testOut
            if ($trc -eq 0) { $ok = $true; break }
            Write-Log "  tests failed (exit $trc) -> $testOut" "Yellow"
        }

        # --- record the result on the EXACT queue line -----------------------
        # Edit by line number, never by String.Replace: Replace() rewrites every
        # identical line in the file, so two same-worded tasks would both be
        # ticked and the second would silently never run.
        #
        # ORDER MATTERS, and it is the opposite of what looks natural: the queue
        # mark is written BEFORE the commit, so that the mark and the work it
        # describes land in the SAME commit. Marking afterwards leaves TASKS.md
        # permanently dirty, which (a) makes every later task look like it
        # changed something and (b) lets `git reset --hard` on a blocked task
        # revert earlier [x] marks and re-run tasks that were already done.
        # The invariant this buys: the tree is clean at the top of every task.
        $lines  = [IO.File]::ReadAllLines($TasksFile)
        $idx    = $lineNo - 1
        $before = $lines[$idx]

        if ($ok) {
            $lines[$idx] = $before -replace '^(\s*-\s*)\[ \]', '${1}[x]'
        } else {
            # Roll back FIRST - that also undoes any edit the executor made to
            # TASKS.md - then re-read and mark the line as blocked.
            if (-not $NoCommit) {
                $null = Invoke-Git -Dir $Root -GitArgs @("reset", "--hard", $base)
                $null = Invoke-Git -Dir $Root -GitArgs @("clean", "-fd")
                $lines  = [IO.File]::ReadAllLines($TasksFile)
                $before = $lines[$idx]
            }
            $lines[$idx] = ($before -replace '^(\s*-\s*)\[ \]', '${1}[!]') + "  <!-- BLOCKED $stamp -->"
        }

        if ($lines[$idx] -eq $before) {
            # The queue line did not change, so the next pass would pick the very
            # same task and spin here forever. Fail loudly instead.
            throw "Could not mark task line $lineNo in TASKS.md. This is a night-run bug. Line was: $before"
        }
        Write-Lines -Path $TasksFile -Lines $lines

        if (-not $NoCommit) {
            $null = Invoke-Git -Dir $Root -GitArgs @("add", "-A")

            # The message goes in via -F, never -m. A task line routinely
            # contains double quotes ("Hello, <name>!"), a $ or a backtick, and
            # PowerShell's native-argument rules would split it mid-message -
            # git then reads the tail as a pathspec and the commit fails.
            # This used to be silent: the failure was swallowed by 2>$null and
            # the task was ticked [x] with nothing committed behind it.
            $msg     = if ($ok) { "feat: $task" } else { "chore: blocked - $task" }
            $msgFile = Join-Path $AgentDir "commit-msg.txt"
            [IO.File]::WriteAllText($msgFile, $msg, (New-Object System.Text.UTF8Encoding $false))

            $c = Invoke-Git -Dir $Root -GitArgs @("commit", "-q", "-F", $msgFile)
            if ($c.Code -ne 0) {
                throw "git commit failed after a task (exit $($c.Code)). Stopping, because the next task would otherwise build on an uncommitted tree.`n$($c.Output)"
            }
        }

        if ($ok) {
            $done++
            Write-Log "  PASSED + committed ($($script:Active))" "Green"
        } else {
            $blocked++
            Write-Log "  BLOCKED - rolled back, moving on" "Red"
        }
    }

    $mins = [int]((Get-Date) - $t0).TotalMinutes
    Write-Log ""
    Write-Log "=== DONE: $done passed, $blocked blocked, $mins min ===" "Cyan"
    Write-Log "In the morning, review blocked tasks:"
    Write-Log "  Select-String -Path '$TasksFile' -Pattern '\[!\]'"
}
finally {
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
}
