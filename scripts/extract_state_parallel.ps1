# extract_state_parallel.ps1
#
# parallel county-level extraction from the nationwide GPKG -> merged hilbert GeoParquet.
#
# strategy:
#   1. compute per-county bboxes by querying the tiger county layer (fast, range request via vsicurl)
#      OR fall back to per-county bboxes from an existing state parquet if available.
#   2. launch $Parallelism concurrent ogr2ogr jobs, each scoped to one county via
#      -spat <county_bbox> + -where "statefp='XX' AND countyfp='YYY'".
#      the rtree handles spatial pre-filtering; the where clause is applied to candidates only.
#   3. merge all county parquets with duckdb and hilbert-sort into the canonical path.
#
# usage:
#   pixi run pwsh -NoProfile -File scripts/extract_state_parallel.ps1 -State 13
#   pixi run pwsh -NoProfile -File scripts/extract_state_parallel.ps1 -State 13 -Parallelism 4
#
param(
    [Parameter(Mandatory=$true)][string]$State,
    [int]$Parallelism = 8,
    [string]$GpkgFile = "LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg",
    [string]$GpkgLayer = "lr_parcel_us"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "    $msg" -ForegroundColor Red }

# ---- resolve county bboxes ----
# prefer existing state parquet (fast duckdb query); fall back to tiger vsicurl
$stateParquet = "data/geoparquet/state=$State/parcels.parquet"
$countyBboxScript = @"
import duckdb, json, sys
con = duckdb.connect()
con.execute('INSTALL spatial; LOAD spatial;')
rows = con.execute(f'''
    SELECT countyfp,
           MIN(ST_XMin(geom)) AS xmin, MIN(ST_YMin(geom)) AS ymin,
           MAX(ST_XMax(geom)) AS xmax, MAX(ST_YMax(geom)) AS ymax
    FROM read_parquet('{$stateParquet.Replace('\','/')}')
    GROUP BY countyfp
    ORDER BY countyfp
''').fetchall()
print(json.dumps([{'fips': r[0], 'bbox': [r[1],r[2],r[3],r[4]]} for r in rows]))
"@

$countyBboxFile = [System.IO.Path]::GetTempFileName() + ".json"

if (Test-Path $stateParquet) {
    Write-Step "computing county bboxes from existing state parquet"
    $bboxJson = pixi run uv run --with duckdb python -c $countyBboxScript
    $bboxJson | Set-Content $countyBboxFile
    $counties = $bboxJson | ConvertFrom-Json
} else {
    Write-Step "fetching county bboxes from TIGER vsicurl (no existing state parquet)"
    # read county features for this state from tiger national counties shapefile
    $tigerUrl = "https://www2.census.gov/geo/tiger/TIGER2024/COUNTY/tl_2024_us_county.zip"
    $tigerQuery = "SELECT COUNTYFP, ST_MinX(geometry) AS xmin, ST_MinY(geometry) AS ymin, ST_MaxX(geometry) AS xmax, ST_MaxY(geometry) AS ymax FROM tl_2024_us_county WHERE STATEFP='$State'"
    $tigerParquet = [System.IO.Path]::GetTempFileName() + ".parquet"
    pixi run ogr2ogr -f Parquet $tigerParquet "/vsizip//vsicurl/$tigerUrl" -sql $tigerQuery 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "failed to fetch TIGER county data"; exit 1 }

    $tigerScript = @"
import duckdb, json
con = duckdb.connect()
con.execute('INSTALL spatial; LOAD spatial;')
rows = con.execute(f"SELECT COUNTYFP, xmin, ymin, xmax, ymax FROM read_parquet('$($tigerParquet.Replace('\','/'))')").fetchall()
print(json.dumps([{'fips': r[0], 'bbox': [r[1],r[2],r[3],r[4]]} for r in rows]))
"@
    $bboxJson = pixi run uv run --with duckdb python -c $tigerScript
    $bboxJson | Set-Content $countyBboxFile
    $counties = $bboxJson | ConvertFrom-Json
    Remove-Item $tigerParquet -ErrorAction SilentlyContinue
}

Write-Ok "found $($counties.Count) counties for state $State"

# ---- per-county extraction function ----
$outDir = "data/geoparquet/state=$State/counties"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Invoke-CountyExtract {
    param([string]$StateFips, [string]$CountyFips, [double[]]$Bbox, [string]$GpkgFile, [string]$GpkgLayer)

    $out = "data/geoparquet/state=$StateFips/counties/county=$CountyFips.parquet"
    if (Test-Path $out) {
        Write-Host "    skip $CountyFips (exists)" -ForegroundColor DarkGray
        return $out
    }

    $env:OGR_SQLITE_PRAGMA = "mmap_size=107374182400,cache_size=-2097152,temp_store=MEMORY,journal_mode=OFF"
    $env:OGR_GPKG_NUM_THREADS = "4"
    $env:GDAL_CACHEMAX = "1024"

    $bboxArgs = @("-spat", $Bbox[0], $Bbox[1], $Bbox[2], $Bbox[3])
    $whereClause = "statefp='$StateFips' AND countyfp='$CountyFips'"

    pixi run ogr2ogr -f Parquet `
        -lco COMPRESSION=ZSTD -lco COMPRESSION_LEVEL=9 -lco ROW_GROUP_SIZE=50000 `
        -lco SORT_BY_BBOX=YES -lco WRITE_COVERING_BBOX=YES `
        @bboxArgs -where $whereClause `
        $out $GpkgFile $GpkgLayer 2>&1

    Remove-Item Env:OGR_SQLITE_PRAGMA -ErrorAction SilentlyContinue
    Remove-Item Env:OGR_GPKG_NUM_THREADS -ErrorAction SilentlyContinue
    Remove-Item Env:GDAL_CACHEMAX -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -eq 0) {
        $sz = [math]::Round((Get-Item $out).Length / 1MB, 1)
        Write-Host "    county=$CountyFips -> $sz MB" -ForegroundColor Green
    } else {
        Write-Host "    county=$CountyFips FAILED" -ForegroundColor Red
    }
    return $out
}

# ---- parallel batch processing ----
Write-Step "extracting $($counties.Count) counties in batches of $Parallelism"
$startTime = Get-Date
$jobs = @()
$completedCount = 0

foreach ($county in $counties) {
    # throttle: wait if we have $Parallelism jobs running
    while (($jobs | Where-Object { $_.State -eq "Running" }).Count -ge $Parallelism) {
        Start-Sleep -Milliseconds 500
        $done = $jobs | Where-Object { $_.State -eq "Completed" -and -not $_.HasFlag }
        foreach ($j in $done) {
            $j | Add-Member -NotePropertyName HasFlag -NotePropertyValue $true -Force
            $completedCount++
        }
    }

    $countyFips = $county.fips
    $bbox = $county.bbox

    $job = Start-Job -ScriptBlock {
        param($sf, $cf, $bb, $gpkg, $layer, $dir)
        Set-Location $dir
        & pwsh -NoProfile -Command {
            param($sf, $cf, $bb, $gpkg, $layer)
            $out = "data/geoparquet/state=$sf/counties/county=$cf.parquet"
            if (Test-Path $out) { Write-Host "skip $cf"; exit 0 }
            $env:OGR_SQLITE_PRAGMA = "mmap_size=107374182400,cache_size=-2097152,temp_store=MEMORY"
            $env:OGR_GPKG_NUM_THREADS = "4"
            pixi run ogr2ogr -f Parquet -lco COMPRESSION=ZSTD -lco COMPRESSION_LEVEL=9 -lco ROW_GROUP_SIZE=50000 -lco SORT_BY_BBOX=YES -lco WRITE_COVERING_BBOX=YES -spat $bb[0] $bb[1] $bb[2] $bb[3] -where "statefp='$sf' AND countyfp='$cf'" $out $gpkg $layer
            exit $LASTEXITCODE
        } -args $sf, $cf, $bb, $gpkg, $layer
    } -ArgumentList $State, $countyFips, $bbox, $GpkgFile, $GpkgLayer, (Get-Location).Path

    $jobs += $job
    Write-Host "  queued county=$countyFips" -ForegroundColor DarkCyan
}

# wait for all remaining jobs
Write-Step "waiting for remaining jobs..."
$jobs | Wait-Job | Out-Null
$failed = $jobs | Where-Object { $_.ChildJobs[0].JobStateInfo.State -eq "Failed" }
if ($failed.Count -gt 0) {
    Write-Err "$($failed.Count) county jobs failed"
}
$jobs | Remove-Job

$elapsed = (Get-Date) - $startTime
Write-Ok "county extraction complete in $([math]::Round($elapsed.TotalMinutes, 1)) minutes"

# ---- merge + hilbert sort ----
Write-Step "merging counties and hilbert-sorting -> state=$State/parcels.parquet"
$countyFiles = Get-ChildItem "data/geoparquet/state=$State/counties" -Filter "*.parquet" | Select-Object -ExpandProperty FullName
if ($countyFiles.Count -eq 0) { Write-Err "no county parquet files found"; exit 1 }

$mergeParquet = "data/geoparquet/state=$State/parcels_merged.parquet"

# build a duckdb glob expression across all county files
$globExpr = "data/geoparquet/state=$State/counties/*.parquet"
$mergeScript = @"
import duckdb, sys
con = duckdb.connect()
con.execute('INSTALL spatial; LOAD spatial;')
con.execute(f"""
    COPY (SELECT * FROM read_parquet('$($globExpr.Replace('\','/'))', union_by_name=true))
    TO '$($mergeParquet.Replace('\','/'))'
    (FORMAT parquet, COMPRESSION zstd, COMPRESSION_LEVEL 3, ROW_GROUP_SIZE 50000)
""")
print(f"merged to $mergeParquet")
"@
pixi run uv run --with duckdb python -c $mergeScript

if ($LASTEXITCODE -ne 0) { Write-Err "merge failed"; exit 1 }

# hilbert sort the merged file
$parquetPath = "data/geoparquet/state=$State/parcels.parquet"
pixi run uv run --with duckdb scripts/to_hilbert_parquet.py $mergeParquet $parquetPath --state $State
if ($LASTEXITCODE -ne 0) { Write-Err "hilbert sort failed"; exit 1 }

Remove-Item $mergeParquet -ErrorAction SilentlyContinue

$totalElapsed = (Get-Date) - $startTime
$sz = [math]::Round((Get-Item $parquetPath).Length / 1MB, 1)
Write-Ok "done: $parquetPath ($sz MB) in $([math]::Round($totalElapsed.TotalMinutes, 1)) minutes total"
Write-Host ""
Write-Host "  county parquets kept in: data/geoparquet/state=$State/counties/" -ForegroundColor DarkGray
Write-Host "  delete them if not needed: Remove-Item data/geoparquet/state=$State/counties -Recurse" -ForegroundColor DarkGray
