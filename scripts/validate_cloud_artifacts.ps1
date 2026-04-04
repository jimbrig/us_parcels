# validate_cloud_artifacts.ps1 - wrapper around the canonical Python validator
# runs DuckDB bbox query, verifies PMTiles file, optionally checks FGB
#
# usage:
#   .\scripts\validate_cloud_artifacts.ps1 -State "13"
#   .\scripts\validate_cloud_artifacts.ps1 -ParquetPath "data/geoparquet/state=13/parcels.parquet" -PmtilesPath "data/pmtiles/state=13/parcels.pmtiles" -FgbPath "data/flatgeobuf/state=13/parcels.fgb"

param(
    [string]$State,
    [string]$ParquetPath,
    [string]$PmtilesPath,
    [string]$FgbPath,
    [string]$Bbox = "-84.5,33.6,-84.2,33.9"
)

$ErrorActionPreference = "Stop"

Write-Warning "Use 'pixi run validate -- ...' as the canonical validation command. This PowerShell wrapper is retained for compatibility."

$cliArgs = @("--bbox", $Bbox)
if ($State) {
    $cliArgs += @("--state", $State)
} else {
    if ($ParquetPath) { $cliArgs += @("--parquet", $ParquetPath) }
    if ($PmtilesPath) { $cliArgs += @("--pmtiles", $PmtilesPath) }
    if ($FgbPath) { $cliArgs += @("--fgb", $FgbPath) }
}

if (-not $State -and (-not $ParquetPath -or -not $PmtilesPath)) {
    Write-Error "provide -State or both -ParquetPath and -PmtilesPath"
    exit 1
}

uv run --with duckdb scripts/validate_cloud_artifacts.py @cliArgs
exit $LASTEXITCODE
