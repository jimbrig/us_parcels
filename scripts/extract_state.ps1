# extract_state.ps1 - deprecated wrapper around pipeline.ps1
# usage: .\scripts\extract_state.ps1 -State "13" -Name "georgia"

param(
    [Parameter(Mandatory=$true)]
    [string]$State,

    [Parameter(Mandatory=$true)]
    [string]$Name,

    [string]$GpkgFile = "LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg",
    [string]$GpkgLayer = "lr_parcel_us",
    [string]$OutputDir = "data/geoparquet"
)

Write-Warning "scripts/extract_state.ps1 is deprecated. Use 'pixi run pipeline -- -Action extract-state -State <fips> -Name <name>' instead."

pwsh -NoProfile -File "$PSScriptRoot/pipeline.ps1" `
    -Action extract-state `
    -State $State `
    -Name $Name `
    -GpkgFile $GpkgFile `
    -GpkgLayer $GpkgLayer

exit $LASTEXITCODE
