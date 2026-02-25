# pipeline.ps1 - unified extract -> load -> export workflow
#
# centralizes PostGIS as the single source of truth.
# extracts from the monolithic GPKG, loads into PostGIS,
# then optionally exports derivative formats (PMTiles, FlatGeoBuf, GeoParquet).
#
# usage:
#   .\scripts\pipeline.ps1 -Action extract-state -State "13" -Name "georgia"
#   .\scripts\pipeline.ps1 -Action extract-bbox -Bbox "-84.40,33.74,-84.37,33.77" -Name "atlanta_dt"
#   .\scripts\pipeline.ps1 -Action load -Source data/geoparquet/georgia.parquet
#   .\scripts\pipeline.ps1 -Action export -Format pmtiles -Name "atlanta_dt"
#   .\scripts\pipeline.ps1 -Action full -State "13" -Name "georgia"
#   .\scripts\pipeline.ps1 -Action status

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("extract-state","extract-bbox","load","export","full","status")]
    [string]$Action,

    [string]$State,
    [string]$Name,
    [string]$Bbox,
    [string]$Source,
    [ValidateSet("parquet","pmtiles","fgb","all")]
    [string]$Format = "all",

    [string]$GpkgFile = "LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg",
    [string]$GpkgLayer = "lr_parcel_us",
    [string]$Table = "parcels.parcel_raw"
)

$PgConn = "PG:host=localhost port=5432 dbname=parcels user=parcels password=parcels"
$DockerPgConn = "PG:host=postgis port=5432 dbname=parcels user=parcels password=parcels"

# state bounding boxes
$StateBounds = @{
    "01" = "-88.47,30.22,-84.89,35.01"   # Alabama
    "04" = "-114.82,31.33,-109.04,37.00"  # Arizona
    "05" = "-94.62,33.00,-89.64,36.50"    # Arkansas
    "06" = "-124.48,32.53,-114.13,42.01"  # California
    "08" = "-109.06,36.99,-102.04,41.00"  # Colorado
    "09" = "-73.73,40.95,-71.79,42.05"    # Connecticut
    "10" = "-75.79,38.45,-75.05,39.84"    # Delaware
    "11" = "-77.12,38.79,-76.91,38.99"    # DC
    "12" = "-87.63,24.52,-80.03,31.00"    # Florida
    "13" = "-85.61,30.36,-80.84,35.00"    # Georgia
    "16" = "-117.24,41.99,-111.04,49.00"  # Idaho
    "17" = "-91.51,36.97,-87.50,42.51"    # Illinois
    "18" = "-88.10,37.77,-84.78,41.76"    # Indiana
    "19" = "-96.64,40.38,-90.14,43.50"    # Iowa
    "20" = "-102.05,36.99,-94.59,40.00"   # Kansas
    "21" = "-89.57,36.50,-81.96,39.15"    # Kentucky
    "22" = "-94.04,28.93,-88.82,33.02"    # Louisiana
    "24" = "-79.49,37.91,-75.05,39.72"    # Maryland
    "25" = "-73.51,41.24,-69.93,42.89"    # Massachusetts
    "26" = "-90.42,41.70,-82.41,48.19"    # Michigan
    "27" = "-97.24,43.50,-89.49,49.38"    # Minnesota
    "29" = "-95.77,35.99,-89.10,40.61"    # Missouri
    "34" = "-75.56,38.93,-73.89,41.36"    # New Jersey
    "36" = "-79.76,40.50,-71.86,45.02"    # New York
    "37" = "-84.32,33.84,-75.46,36.59"    # North Carolina
    "39" = "-84.82,38.40,-80.52,42.33"    # Ohio
    "42" = "-80.52,39.72,-74.69,42.27"    # Pennsylvania
    "47" = "-90.31,34.98,-81.65,36.68"    # Tennessee
    "48" = "-106.65,25.84,-93.51,36.50"   # Texas
    "51" = "-83.68,36.54,-75.24,39.47"    # Virginia
    "53" = "-124.85,45.54,-116.92,49.00"  # Washington
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "    $msg" -ForegroundColor Red }

function Get-BboxArray([string]$bboxStr) {
    return $bboxStr.Split(",") | ForEach-Object { $_.Trim() }
}

function Invoke-Extract {
    param([string]$bbox, [string]$outName, [string]$fmt = "Parquet")

    $b = Get-BboxArray $bbox
    $ext = switch ($fmt) { "Parquet" { "parquet" } "FlatGeoBuf" { "fgb" } "PMTiles" { "pmtiles" } }
    $subdir = switch ($fmt) { "Parquet" { "geoparquet" } "FlatGeoBuf" { "flatgeobuf" } "PMTiles" { "pmtiles" } }
    $outFile = "data/$subdir/${outName}.$ext"

    $outDir = Split-Path $outFile -Parent
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    Write-Step "extracting $outName ($fmt) with bbox: $bbox"

    $args = @("-f", $fmt)
    if ($fmt -eq "Parquet") {
        $args += @("-lco", "COMPRESSION=ZSTD", "-lco", "GEOMETRY_ENCODING=GEOARROW")
    }
    if ($fmt -eq "PMTiles") {
        $args += @("-dsco", "MINZOOM=12", "-dsco", "MAXZOOM=16", "-dsco", "NAME=$outName")
    }
    $args += @("-spat", $b[0], $b[1], $b[2], $b[3], "-progress", $outFile, $GpkgFile, $GpkgLayer)

    pixi run ogr2ogr @args

    if ($LASTEXITCODE -eq 0) {
        $size = (Get-Item $outFile).Length / 1MB
        Write-Ok "$outFile ($([math]::Round($size, 2)) MB)"
    } else {
        Write-Err "extraction failed"
    }
    return $outFile
}

function Invoke-Load {
    param([string]$sourceFile, [string]$targetTable)

    Write-Step "loading $sourceFile into PostGIS ($targetTable)"

    docker compose --profile tools run --rm gdal ogr2ogr `
        -f PostgreSQL $DockerPgConn `
        $sourceFile `
        -nln $targetTable `
        -lco GEOMETRY_NAME=geom `
        -lco SPATIAL_INDEX=NONE `
        -lco PRECISION=NO `
        -append -progress `
        --config PG_USE_COPY YES

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "loaded into $targetTable"
        Write-Step "building spatial index"
        $idxName = $targetTable.Replace(".", "_")
        docker compose exec postgis psql -U parcels -d parcels -c `
            "CREATE INDEX IF NOT EXISTS idx_${idxName}_geom ON $targetTable USING gist(geom);"
        Write-Ok "spatial index built"
    } else {
        Write-Err "load failed"
    }
}

function Invoke-Export {
    param([string]$outName, [string]$fmt, [string]$sourceTable)

    $ext = switch ($fmt) { "parquet" { "parquet" } "pmtiles" { "pmtiles" } "fgb" { "fgb" } }
    $driver = switch ($fmt) { "parquet" { "Parquet" } "pmtiles" { "PMTiles" } "fgb" { "FlatGeoBuf" } }
    $subdir = switch ($fmt) { "parquet" { "geoparquet" } "pmtiles" { "pmtiles" } "fgb" { "flatgeobuf" } }
    $outFile = "data/$subdir/${outName}.$ext"

    $outDir = Split-Path $outFile -Parent
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    Write-Step "exporting $sourceTable -> $outFile ($driver)"

    $args = @(
        "compose", "--profile", "tools", "run", "--rm", "gdal",
        "ogr2ogr", "-f", $driver
    )

    if ($fmt -eq "parquet") {
        $args += @("-lco", "COMPRESSION=ZSTD", "-lco", "GEOMETRY_ENCODING=GEOARROW")
    }
    if ($fmt -eq "pmtiles") {
        $args += @("-dsco", "MINZOOM=12", "-dsco", "MAXZOOM=16", "-dsco", "NAME=$outName")
    }

    $args += @("-progress", $outFile, $DockerPgConn, $sourceTable)

    & docker @args

    if ($LASTEXITCODE -eq 0) {
        $size = (Get-Item $outFile).Length / 1MB
        Write-Ok "$outFile ($([math]::Round($size, 2)) MB)"
    } else {
        Write-Err "export failed"
    }
}

function Invoke-Status {
    Write-Step "PostGIS tables"
    docker compose exec postgis psql -U parcels -d parcels -c `
        "SELECT relname as table_name, n_live_tup as rows FROM pg_stat_user_tables WHERE schemaname='parcels' ORDER BY relname;"
    Write-Step "spatial extent of parcel_raw"
    docker compose exec postgis psql -U parcels -d parcels -c `
        "SELECT COUNT(*) as total, ST_Extent(geom)::text as extent FROM parcels.parcel_raw;"
    Write-Step "data files on disk"
    Get-ChildItem data -Recurse -File -Exclude ".gitkeep" | 
        Select-Object @{N="Path";E={$_.FullName.Replace((Get-Location).Path + "\", "")}}, @{N="Size_MB";E={[math]::Round($_.Length/1MB, 2)}} |
        Format-Table -AutoSize
}

# ---- dispatch ----
switch ($Action) {
    "extract-state" {
        if (-not $State -or -not $Name) { Write-Error "-State and -Name are required"; exit 1 }
        if (-not $StateBounds.ContainsKey($State)) { Write-Error "unknown state FIPS: $State"; exit 1 }
        Invoke-Extract -bbox $StateBounds[$State] -outName $Name -fmt "Parquet"
    }
    "extract-bbox" {
        if (-not $Bbox -or -not $Name) { Write-Error "-Bbox and -Name are required"; exit 1 }
        Invoke-Extract -bbox $Bbox -outName $Name -fmt "Parquet"
    }
    "load" {
        if (-not $Source) { Write-Error "-Source is required"; exit 1 }
        Invoke-Load -sourceFile $Source -targetTable $Table
    }
    "export" {
        if (-not $Name) { Write-Error "-Name is required"; exit 1 }
        if ($Format -eq "all") {
            foreach ($f in @("parquet", "pmtiles", "fgb")) {
                Invoke-Export -outName $Name -fmt $f -sourceTable $Table
            }
        } else {
            Invoke-Export -outName $Name -fmt $Format -sourceTable $Table
        }
    }
    "full" {
        if (-not $State -or -not $Name) { Write-Error "-State and -Name required for full pipeline"; exit 1 }
        if (-not $StateBounds.ContainsKey($State)) { Write-Error "unknown state FIPS: $State"; exit 1 }
        Write-Host "`n======================================" -ForegroundColor Yellow
        Write-Host " Full Pipeline: $Name (state $State)" -ForegroundColor Yellow
        Write-Host "======================================`n" -ForegroundColor Yellow

        $parquetFile = Invoke-Extract -bbox $StateBounds[$State] -outName $Name -fmt "Parquet"
        Invoke-Load -sourceFile "data/geoparquet/${Name}.parquet" -targetTable $Table

        Write-Step "exporting derivative formats from PostGIS"
        foreach ($f in @("pmtiles", "fgb")) {
            Invoke-Export -outName $Name -fmt $f -sourceTable $Table
        }

        Write-Host "`n======================================" -ForegroundColor Green
        Write-Host " Pipeline complete for $Name" -ForegroundColor Green
        Write-Host "======================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  PostGIS:        $Table" -ForegroundColor White
        Write-Host "  Martin tiles:   http://localhost:3000 (auto-discovered)" -ForegroundColor White
        Write-Host "  pg_tileserv:    http://localhost:7800" -ForegroundColor White
        Write-Host "  pg_featureserv: http://localhost:9000" -ForegroundColor White
        Write-Host "  GeoParquet:     data/geoparquet/${Name}.parquet" -ForegroundColor White
        Write-Host "  PMTiles:        data/pmtiles/${Name}.pmtiles" -ForegroundColor White
        Write-Host "  FlatGeoBuf:     data/flatgeobuf/${Name}.fgb" -ForegroundColor White
    }
    "status" {
        Invoke-Status
    }
}
