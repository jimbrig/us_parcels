# ingest_postgis.ps1 - load geospatial files into PostGIS via Docker GDAL
#
# usage:
#   .\scripts\ingest_postgis.ps1 -Source data/geoparquet/georgia.parquet
#   .\scripts\ingest_postgis.ps1 -Source data/flatgeobuf/atlanta_downtown.fgb -Table parcels.atlanta
#   .\scripts\ingest_postgis.ps1 -Source LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg -Layer lr_parcel_us

param(
    [Parameter(Mandatory=$true)]
    [string]$Source,

    [string]$Layer = "",
    [string]$Table = "parcels.parcel_raw",
    [switch]$Replace,
    [switch]$BuildIndex
)

$layerArg = if ($Layer) { $Layer } else { "" }
$modeArg = if ($Replace) { "-overwrite" } else { "-append" }

Write-Host "================================================================"
Write-Host " PostGIS Ingest (Docker GDAL)"
Write-Host "================================================================"
Write-Host " source:  $Source"
Write-Host " layer:   $(if ($Layer) { $Layer } else { '<auto>' })"
Write-Host " target:  $Table"
Write-Host " mode:    $(if ($Replace) { 'replace' } else { 'append' })"
Write-Host "================================================================"

$args = @(
    "compose", "--profile", "tools", "run", "--rm", "gdal",
    "ogr2ogr",
    "-f", "PostgreSQL",
    "PG:host=postgis port=5432 dbname=parcels user=parcels password=parcels",
    $Source
)

if ($Layer) { $args += $Layer }

$args += @(
    "-nln", $Table,
    "-lco", "GEOMETRY_NAME=geom",
    "-lco", "SPATIAL_INDEX=NONE",
    "-lco", "PRECISION=NO",
    $modeArg,
    "-progress",
    "--config", "PG_USE_COPY", "YES"
)

& docker @args

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n==> loaded into $Table" -ForegroundColor Green

    if ($BuildIndex) {
        Write-Host "==> building spatial index..." -ForegroundColor Yellow
        docker compose exec postgis psql -U parcels -d parcels -c "CREATE INDEX IF NOT EXISTS idx_${Table.Replace('.','_')}_geom ON $Table USING gist(geom);"
        Write-Host "==> spatial index built" -ForegroundColor Green
    } else {
        Write-Host "`nnext steps:" -ForegroundColor Cyan
        Write-Host "  docker compose exec postgis psql -U parcels -d parcels"
        Write-Host "  CREATE INDEX ON $Table USING gist(geom);"
        Write-Host "  SELECT COUNT(*) FROM $Table;"
    }
} else {
    Write-Error "Ingestion failed"
}
