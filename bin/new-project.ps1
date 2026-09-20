<#
    new-project.ps1 - get a project ready for night-run, in one command.

    Does the four things that are easy to forget, and refuses to do damage:
      1. makes the folder if it does not exist
      2. copies AGENTS.md and TASKS.md from the templates, NEVER overwriting
         one that is already there
      3. git init plus a first commit, because rollback needs a commit to
         return to
      4. runs the real preflight so you find out now, not at 02:00, whether
         the executor and its credentials are actually usable

    USAGE
        .\new-project.ps1 -Root "D:\work\acme-site"
        .\new-project.ps1 -Root "D:\work\acme-site" -Starter   # with the demo queue
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [switch]$Starter          # seed from workflow\starter instead of the blank templates
)

$ErrorActionPreference = "Stop"

$Here      = Split-Path $MyInvocation.MyCommand.Path -Parent
$AiRoot    = Split-Path $Here -Parent
$Templates = Join-Path $AiRoot "workflow\templates"
$StarterD  = Join-Path $AiRoot "workflow\starter"
$NightRun  = Join-Path $Here "night-run.ps1"

function Say { param([string]$m, [string]$c = "Gray") Write-Host $m -ForegroundColor $c }

# Same reason as night-run.ps1: under $ErrorActionPreference = "Stop", letting a
# native command's stderr through wraps it in a NativeCommandError record and
# THROWS - so a routine "not a git repository" probe kills the script instead of
# answering the question it was asked.
function Invoke-Git {
    param([string]$Dir, [string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & git -C $Dir @GitArgs 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out -join "`n"); Lines = @($out) }
    } finally { $ErrorActionPreference = $prev }
}

# ---------------------------------------------------------------- 1. folder ---
if (-not (Test-Path $Root)) {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Say "created  $Root" "Green"
} else {
    Say "exists   $Root"
}
$Root = (Resolve-Path $Root).Path

# ------------------------------------------------------------- 2. the files ---
# Never clobber. A TASKS.md already in place is someone's queue, possibly with
# [x] history in it, and silently replacing it would erase a night's record.
$source = if ($Starter) { $StarterD } else { $Templates }
if (-not (Test-Path $source)) { throw "Template source not found: $source" }

foreach ($f in (Get-ChildItem $source -File -Recurse)) {
    $rel  = $f.FullName.Substring($source.Length).TrimStart('\')
    $dest = Join-Path $Root $rel
    if (Test-Path $dest) {
        Say "kept     $rel  (already present, left alone)" "Yellow"
        continue
    }
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    Copy-Item $f.FullName $dest
    Say "added    $rel" "Green"
}

# -------------------------------------------------------------------- 3. git ---
if ((Invoke-Git -Dir $Root -GitArgs @("rev-parse","--is-inside-work-tree")).Code -ne 0) {
    $null = Invoke-Git -Dir $Root -GitArgs @("init","-q")
    Say "git      initialised" "Green"
} else {
    Say "git      already a repository"
}

# A repo with no commits has no HEAD, so there is nothing for a rollback to
# reset to. Make that first commit here rather than failing at preflight.
if ((Invoke-Git -Dir $Root -GitArgs @("rev-parse","HEAD")).Code -ne 0) {
    $null = Invoke-Git -Dir $Root -GitArgs @("add","-A")
    $c = Invoke-Git -Dir $Root -GitArgs @("commit","-q","-m","init")
    if ($c.Code -ne 0) {
        throw "Could not make the first commit. Is git user.name / user.email set?`n$($c.Output)"
    }
    Say "git      first commit made" "Green"
} else {
    $dirty = (Invoke-Git -Dir $Root -GitArgs @("status","--porcelain")).Lines | Where-Object { $_ }
    if ($dirty) {
        Say "git      WORKING TREE IS DIRTY - commit or stash before running" "Yellow"
    } else {
        Say "git      clean, has commits"
    }
}

# -------------------------------------------------------------- 4. preflight ---
Say ""
Say "--- preflight (dry run: no model calls, no writes) ---" "Cyan"
& $NightRun -Root $Root -DryRun

Say ""
Say "NEXT" "Cyan"
Say "  1. Put your requirements in the project, then ask Claude Code:"
Say "       read REQUIREMENTS.md and write TASKS.md plus the tests"
Say "     Writing a good queue is the job that decides the night. Keep it."
Say "  2. Check it:    D:\ai\bin\night-run.ps1 -Root `"$Root`" -DryRun"
Say "  3. Run it:      D:\ai\bin\night-run.ps1 -Root `"$Root`""
Say "  4. Review it:   cd `"$Root`"; git log --oneline"
Say "                  Select-String TASKS.md -Pattern '\[!\]'"
