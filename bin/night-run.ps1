<#
    night-run.ps1 - unattended task runner for a local llama.cpp + opencode setup.

    ONE TASK PER MODEL CALL, FRESH CONTEXT EACH TIME.
    That is the whole trick. A single long-running prompt always dies: context
    fills, errors compound, and nothing verifies the result. This loop instead:
        pick one task -> run it in a clean session -> run the tests
        -> green: git commit and mark [x]
        -> red:   git reset --hard and mark [!] BLOCKED, then move on
    So a task that goes wrong costs you one task, not the whole night.

    USAGE
        .\night-run.ps1 -Root "D:\work\my-project"
        .\night-run.ps1 -Root "D:\work\my-project" -TestCmd "php artisan test" -TaskTimeoutMin 25
        .\night-run.ps1 -Root "D:\work\my-project" -DryRun     # plan only, no model, no writes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [string]$TestCmd        = "",                 # auto-detected when empty
    [string]$Model          = "local/gpt-oss-20b",
    [string]$ServerUrl      = "http://127.0.0.1:8080",
    [int]   $TaskTimeoutMin = 20,
    [int]   $MaxRetries     = 1,
    [switch]$NoCommit,
    [switch]$AllowTestEdits,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------- helpers ---
function Write-Log {
    param([string]$Msg, [string]$Color = "Gray")
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Msg
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $script:LogFile -Value $line -Encoding utf8
}

function Resolve-OpenCodeExe {
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "opencode is not on PATH. Run: npm install -g opencode-ai" }
    if ($cmd.Source -like "*.exe") { return $cmd.Source }
    # npm / FlyEnv install a .ps1 shim; Start-Process needs the real .exe
    $exe = Join-Path (Split-Path $cmd.Source -Parent) "node_modules\opencode-ai\bin\opencode.exe"
    if (Test-Path $exe) { return $exe }
    throw "Found shim '$($cmd.Source)' but no opencode.exe beside it."
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
    foreach ($line in (& git -C $Dir status --porcelain)) {
        $f = ($line.Substring(2)).Trim() -replace '\\', '/' -replace '^"|"$', ''
        foreach ($p in $patterns) { if ($f -match $p) { return $f } }
    }
    return $null
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

# Runs a native command with a hard timeout. Returns its exit code, or -1 on timeout.
# Start-Process is used deliberately: in PowerShell 5.1, piping a native command
# with 2>&1 wraps stderr in NativeCommandError records and corrupts $LASTEXITCODE.
function Invoke-WithTimeout {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkDir,
          [int]$TimeoutSec, [string]$OutFile)

    $errFile = "$OutFile.err"
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
                       -WorkingDirectory $WorkDir -NoNewWindow -PassThru `
                       -RedirectStandardOutput $OutFile -RedirectStandardError $errFile

    # MUST cache the process handle before the process exits, otherwise
    # $p.ExitCode is silently $null and every task looks like a failure.
    # This is a real PowerShell trap, not defensive noise:
    #   Start-Process -PassThru, no .Handle read -> $p.ExitCode = ''
    #   Start-Process -PassThru, .Handle cached  -> $p.ExitCode = 0
    $null = $p.Handle

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        Write-Log "  TIMEOUT after $TimeoutSec s - killing process tree" "Red"
        try { taskkill /PID $p.Id /T /F | Out-Null } catch { }
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
& git -C $Root rev-parse --is-inside-work-tree 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "$Root is not a git repository. Run git init and make one commit first - rollback depends on it."
}

# .git/info/exclude is local and untracked, so writing here cannot dirty the tree
$excludeFile = Join-Path $Root ".git\info\exclude"
if (Test-Path $excludeFile) {
    $ex = Get-Content $excludeFile -Raw -ErrorAction SilentlyContinue
    if ($ex -notmatch '(?m)^\.agent/\s*$') {
        Add-Content -Path $excludeFile -Value "`n.agent/" -Encoding utf8
    }
}

$dirty = & git -C $Root status --porcelain
if ($dirty) {
    throw "Working tree is dirty. Commit or stash first, otherwise a rollback will destroy your own changes.`n$($dirty -join "`n")"
}

New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null

$stamp          = Get-Date -Format "yyyyMMdd-HHmm"
$script:LogFile = Join-Path $AgentDir "night-$stamp.log"

# Single-instance lock. Two runners - or a runner plus a benchmark - will each
# load a ~13 GB model and thrash a 32 GB machine into uselessness.
$lock = Join-Path $AgentDir "night-run.lock"
if (Test-Path $lock) {
    $owner = (Get-Content $lock -Raw).Trim()
    throw "A night-run is already active (lock: $lock, started $owner). Delete the lock if it is stale."
}
Set-Content -Path $lock -Value (Get-Date -Format "s") -Encoding utf8

try {
    Write-Log "=== NIGHT RUN START ===" "Cyan"
    Write-Log "root    : $Root"

    if (-not $TestCmd) { $TestCmd = Get-TestCommand -Dir $Root }
    if (-not $TestCmd) {
        Write-Log "WARNING: no test command detected. Tasks will be committed UNVERIFIED." "Yellow"
    } else {
        Write-Log "tests   : $TestCmd"
    }

    $ocExe = Resolve-OpenCodeExe
    Write-Log "opencode: $ocExe"

    try {
        $h = Invoke-RestMethod "$ServerUrl/health" -TimeoutSec 10
        if ($h.status -ne "ok") { throw "status=$($h.status)" }
    } catch {
        throw "llama-server is not healthy at $ServerUrl. Start it with: D:\ai\bin\start-server.ps1"
    }
    Write-Log "server  : ok ($Model)"

    if ($DryRun) {
        Write-Log "--- DRY RUN: queued tasks ---" "Cyan"
        Select-String -Path $TasksFile -Pattern '^\s*-\s*\[ \]\s+(.+)$' |
            ForEach-Object { Write-Log ("  . " + $_.Matches[0].Groups[1].Value) }
        Write-Log "--- no model calls, no writes ---" "Cyan"
        return
    }

    # ----------------------------------------------------------- main loop ---
    $done = 0; $blocked = 0; $t0 = Get-Date

    while ($true) {
        $hit = Select-String -Path $TasksFile -Pattern '^\s*-\s*\[ \]\s+(.+)$' | Select-Object -First 1
        if (-not $hit) { Write-Log "=== QUEUE EMPTY ===" "Cyan"; break }

        $task    = $hit.Matches[0].Groups[1].Value.Trim()
        $taskRaw = $hit.Line
        Write-Log ""
        Write-Log "TASK: $task" "Cyan"

        $base = (& git -C $Root rev-parse HEAD).Trim()
        $ok   = $false

        for ($try = 1; $try -le ($MaxRetries + 1); $try++) {
            if ($try -gt 1) { Write-Log "  retry $($try - 1) of $MaxRetries" "Yellow" }

            # The prompt is deliberately SHORT and STABLE across tasks:
            # llama-server caches the common prefix, so identical wording is
            # genuinely faster. The real rules live in AGENTS.md, which
            # opencode loads on its own.
            $prompt = "Task: $task`n`n" +
                      "Follow AGENTS.md exactly.`n" +
                      "Change only what this task requires. Do not refactor or tidy anything else.`n" +
                      "When the task is done, stop. Do not start another task."

            $n       = $done + $blocked + 1
            $outFile = Join-Path $AgentDir ("task-{0}-{1:d3}.log" -f $stamp, $n)

            $rc = Invoke-WithTimeout -FilePath $ocExe `
                     -Arguments @("run", "--auto", "--model", $Model, $prompt) `
                     -WorkDir $Root -TimeoutSec ($TaskTimeoutMin * 60) -OutFile $outFile

            if ($rc -ne 0) { Write-Log "  opencode exited $rc -> $outFile" "Yellow"; continue }

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

        $content = Get-Content $TasksFile -Raw
        if ($ok) {
            if (-not $NoCommit) {
                & git -C $Root add -A
                & git -C $Root commit -q -m "feat: $task" 1>$null 2>$null
            }
            $content = $content.Replace($taskRaw, $taskRaw.Replace("- [ ]", "- [x]"))
            $done++
            Write-Log "  PASSED + committed" "Green"
        } else {
            & git -C $Root reset --hard $base 1>$null 2>$null
            & git -C $Root clean -fd 1>$null 2>$null
            $content = $content.Replace($taskRaw, $taskRaw.Replace("- [ ]", "- [!]") + "  <!-- BLOCKED $stamp -->")
            $blocked++
            Write-Log "  BLOCKED - rolled back, moving on" "Red"
        }
        Set-Content -Path $TasksFile -Value $content -Encoding utf8 -NoNewline
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
