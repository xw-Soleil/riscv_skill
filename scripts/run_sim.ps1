param(
    [string]$Repo,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

function Find-CacheLabRepo {
    if ($Repo) { return (Resolve-Path $Repo).Path }
    if ($env:CACHE_LAB_REPO) { return (Resolve-Path $env:CACHE_LAB_REPO).Path }
    $dir = (Get-Location).Path
    while ($true) {
        if ((Test-Path (Join-Path $dir 'rtl')) -and (Test-Path (Join-Path $dir 'tb')) -and (Test-Path (Join-Path $dir 'programs'))) {
            return $dir
        }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir -or -not $parent) { break }
        $dir = $parent
    }
    throw 'Cannot locate CPU_Lab2-style repo. Run from the project root or pass -Repo /path/to/CPU_Lab2.'
}

if ($Args.Count -gt 0 -and $Args[0] -eq '--repo') {
    $Repo = $Args[1]
    $Args = $Args[2..($Args.Count - 1)]
}

$Root = Find-CacheLabRepo
$env:CACHE_LAB_REPO = $Root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BashScript = Join-Path $ScriptDir 'run_sim.sh'
& bash $BashScript --repo $Root @Args
exit $LASTEXITCODE
