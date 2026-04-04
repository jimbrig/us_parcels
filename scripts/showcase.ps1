# showcase.ps1 - run cloud pipeline on minimal sample (no GPKG required)
# demonstrates: GeoJSON -> FGB -> Hilbert GeoParquet -> PMTiles -> validation
#
# usage: .\scripts\showcase.ps1
# requires: pixi (ogr2ogr), uv (duckdb), docker compose (gdal for PMTiles)

$ErrorActionPreference = "Stop"
$SampleDir = "data/sample"
$ShowcaseDir = "$SampleDir/showcase"
$Geojson = "$SampleDir/showcase.geojson"
$Fgb = "$ShowcaseDir/parcels.fgb"
$Parquet = "$ShowcaseDir/parcels.parquet"
$Pmtiles = "$ShowcaseDir/parcels.pmtiles"
$Bbox = "-84.39,33.75,-84.386,33.753"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "    $msg" -ForegroundColor Red }

Write-Host "`n======================================" -ForegroundColor Yellow
Write-Host " Cloud Pipeline Showcase (minimal sample)" -ForegroundColor Yellow
Write-Host "======================================`n" -ForegroundColor Yellow

if (-not (Test-Path $Geojson)) {
    Write-Err "sample not found: $Geojson"
    exit 1
}

New-Item -ItemType Directory -Path $ShowcaseDir -Force | Out-Null

Write-Step "1. GeoJSON -> FlatGeoBuf"
pixi run ogr2ogr -f FlatGeoBuf -progress $Fgb $Geojson
if ($LASTEXITCODE -ne 0) { Write-Err "FGB conversion failed"; exit 1 }
$size = (Get-Item $Fgb).Length / 1KB
Write-Ok "$Fgb ($([math]::Round($size, 2)) KB)"

Write-Step "2. FGB -> Hilbert GeoParquet (DuckDB)"
uv run --with duckdb scripts/fgb_to_hilbert_parquet.py $Fgb $Parquet '--bbox=-84.39,33.75,-84.386,33.753'
if ($LASTEXITCODE -ne 0) { Write-Err "Hilbert conversion failed"; exit 1 }
$size = (Get-Item $Parquet).Length / 1KB
Write-Ok "$Parquet ($([math]::Round($size, 2)) KB)"

Write-Step "3. FGB -> PMTiles (GDAL)"
docker compose --profile tools run --rm gdal ogr2ogr `
    -f PMTiles `
    -dsco MINZOOM=8 `
    -dsco MAXZOOM=16 `
    -dsco NAME=parcels `
    -progress $Pmtiles $Fgb
if ($LASTEXITCODE -ne 0) { Write-Err "PMTiles conversion failed"; exit 1 }
$size = (Get-Item $Pmtiles).Length / 1KB
Write-Ok "$Pmtiles ($([math]::Round($size, 2)) KB)"

Write-Step "4. Validation"
uv run --with duckdb scripts/validate_cloud_artifacts.py --parquet $Parquet --pmtiles $Pmtiles --fgb $Fgb '--bbox=-84.39,33.75,-84.386,33.753'
if ($LASTEXITCODE -ne 0) { Write-Err "validation failed"; exit 1 }

Write-Host "`n======================================" -ForegroundColor Green
Write-Host " Showcase complete" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Artifacts:" -ForegroundColor White
Write-Host "    FGB:       $Fgb" -ForegroundColor Gray
Write-Host "    GeoParquet: $Parquet" -ForegroundColor Gray
Write-Host "    PMTiles:   $Pmtiles" -ForegroundColor Gray
Write-Host ""
Write-Host "  View in map:" -ForegroundColor White
Write-Host "    Add showcase source to map.html or open:" -ForegroundColor Gray
Write-Host "    http://localhost:8080/map.html" -ForegroundColor Gray
Write-Host "    Use pmtiles://http://localhost:8080/data/sample/showcase/parcels.pmtiles" -ForegroundColor Gray
Write-Host ""
