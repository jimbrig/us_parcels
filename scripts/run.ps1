# run.ps1 - deprecated helper for direct script execution
# usage: pwsh -NoProfile -File scripts/run.ps1 scripts/showcase.ps1
#        pwsh -NoProfile -File scripts/run.ps1 scripts/pipeline.ps1 -Action status
#
# prefer:
#   pwsh -NoProfile -File scripts/showcase.ps1
#   pixi run showcase

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Script,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

$scriptPath = $Script
if (-not [System.IO.Path]::IsPathRooted($Script)) {
    $fromRoot = Join-Path (Get-Location) $Script
    $fromScripts = Join-Path $PSScriptRoot (Split-Path $Script -Leaf)
    if (Test-Path $fromRoot) { $scriptPath = $fromRoot }
    elseif (Test-Path $fromScripts) { $scriptPath = $fromScripts }
    else { $scriptPath = $fromRoot }
}
if (-not (Test-Path $scriptPath)) {
    Write-Error "script not found: $Script"
    exit 1
}
Write-Warning "scripts/run.ps1 is deprecated. Prefer direct 'pwsh -NoProfile -File ...' or 'pixi run ...' commands."
& $scriptPath @Remaining
exit $LASTEXITCODE
