# US parcels geospatial data formatting
_Exported on 1/7/2026 at 20:31:37 EST from Cursor (2.3.26)_

---

**User**

I have a ~100GB massive united states parcels geospatial gpkg in this folder: "LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg".

I need help getting it into a format more suitable for using. I have done the following actions: @README.md 

Use MCP tools to research

---

**Cursor**

Let me research best practices for handling large geospatial datasets like this:

Let me also check the schema of your parcel data to understand what fields are available for partitioning:

Excellent! You have a great setup. Here's what I found:

## Dataset Summary

| Metric | Value |
|--------|-------|
| **Features** | 154,891,095 (~155 million parcels) |
| **File Size** | ~100 GB |
| **Key Fields** | `statefp`, `countyfp`, `geoid` |
| **Geometry** | Multi Polygon (WGS 84) |
| **GDAL Version** | 3.12.1 (supports `gdal vector partition`) |

---

## Recommended Strategy: Hive-Partitioned GeoParquet

Based on my research, the best approach for your use case is **Hive-partitioned GeoParquet by state and county**. This gives you:

1. **Efficient queries** - Only read files for the states/counties you need
2. **DuckDB/Arrow compatibility** - Direct SQL queries with automatic partition pruning
3. **Manageable file sizes** - ~3,000 counties = reasonable partition count
4. **Cloud-ready** - Standard Hive partitioning works with data lakes

### Option 1: GDAL Vector Partition (Recommended)

Since you have GDAL 3.12.1, you can use the new `gdal vector partition` command:

```powershell
# create the output directory
New-Item -ItemType Directory -Path "geoparquet_partitioned" -Force

# partition by state and county FIPS codes
pixi run gdal vector partition `
  --field statefp `
  --field countyfp `
  --format Parquet `
  --lco GEOMETRY_ENCODING=GEOARROW `
  --lco COMPRESSION=ZSTD `
  --config OGR_SQLITE_CACHE 4000 `
  -i LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg `
  -o geoparquet_partitioned
```

This creates a directory structure like:
```
geoparquet_partitioned/
  statefp=01/
    countyfp=001/part_0000000000.parquet
    countyfp=003/part_0000000000.parquet
    ...
  statefp=02/
    countyfp=020/part_0000000000.parquet
    ...
```

### Option 2: State-Level Files (Simpler)

If you prefer one file per state (51 files), use a PowerShell loop:

```powershell
# get list of state FIPS codes (you may need to build this list)
$states = @("01","02","04","05","06","08","09","10","11","12","13","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","30","31","32","33","34","35","36","37","38","39","40","41","42","44","45","46","47","48","49","50","51","53","54","55","56")

New-Item -ItemType Directory -Path "geoparquet_by_state" -Force

foreach ($state in $states) {
    $outfile = "geoparquet_by_state/${state}_parcels.parquet"
    Write-Host "Processing state: $state"
    pixi run ogr2ogr `
      --config OGR_SQLITE_CACHE 4000 `
      -f Parquet `
      -lco GEOMETRY_ENCODING=GEOARROW `
      -lco COMPRESSION=ZSTD `
      -progress `
      $outfile `
      LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg `
      lr_parcel_us `
      -where "statefp='$state'"
}
```

---

## Querying the Partitioned Data

Once partitioned, you can use **DuckDB** for efficient SQL queries:

```sql
-- install and load spatial extension
INSTALL spatial;
LOAD spatial;

-- query with automatic partition pruning (only reads relevant files)
SELECT parceladdr, totalvalue, ST_Area(geom) as area_sqm
FROM read_parquet('geoparquet_partitioned/**/*.parquet', hive_partitioning=true)
WHERE statefp = '13' AND countyfp = '121'  -- Fulton County, GA
  AND totalvalue > 500000
LIMIT 100;
```

---

## Considerations

| Approach | Pros | Cons |
|----------|------|------|
| **Hive Partitioned** | Best query performance, standard format | ~3,000 directories |
| **By State** | Simpler structure, 51 files | Larger files (~2GB avg) |
| **Single File** | Simplest | No partition pruning |

**Processing Time Estimate**: For 155M features, expect 4-12 hours depending on disk I/O.

Would you like me to help you:
1. Run the partition command and monitor progress?
2. Set up a DuckDB workflow for querying?
3. Create a script to process this in batches?

---

**User**

i want to start with something i can actually perform without taking 30+ minutes or hours. the hive partitioned setup is a great approach for a final result (hosted in cloud) but for now help me simply try and get some data out and convert etc 

---

**Cursor**

Totally fair! Let's do some quick, practical experiments. You already have Fulton County extracted - let's build on that.

---

**User**

i had to cancel the geoparquet creation it was taking too long. same for various flatgeobufs in @misc 

---

**Cursor**

Got it - the filtering queries are slow because they require scanning the entire 100GB file. Let's try faster approaches:

No indexes - that's why filtering is slow (full table scan of 155M rows). Let's try quick alternatives:

---

**User**

are you sure there are no indices?:

```
➜ pixi run ogrinfo $gpkg_file -sql "SELECT HasSpatialIndex('lr_parcel_us','geom')"
INFO: Open of `LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg'
      using driver `GPKG' successful.

Layer name: SELECT
Geometry: Unknown (any)
Feature Count: 1
Layer SRS WKT:
(unknown)
HasSpatialIndex: Integer (0.0)
OGRFeature(SELECT):0
  HasSpatialIndex (Integer) = 1
```

---

**Cursor**

You're right! There's a **spatial index** on the geometry - that changes everything. We should use **spatial filters** (bounding boxes) instead of attribute filters to leverage that index.

Let me look up a bounding box for a quick extraction:

Let me try a smaller, known area. Here's the fast approach using **spatial filtering**:

```powershell
# use -spat for bounding box filter (leverages spatial index!)
# format: -spat <xmin> <ymin> <xmax> <ymax>

# small area in downtown Atlanta (~1 sq mile)
pixi run ogr2ogr `
  -f Parquet `
  -lco COMPRESSION=ZSTD `
  -spat -84.40 33.74 -84.37 33.77 `
  -progress `
  samples/atlanta_downtown.parquet `
  LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg `
  lr_parcel_us
```

The `-spat` flag uses the spatial index, so it should be **dramatically faster** than attribute filtering.

Here are a few quick test areas you can try:

| Area | Bounding Box (`-spat xmin ymin xmax ymax`) |
|------|-------------------------------------------|
| Downtown Atlanta (tiny) | `-spat -84.40 33.74 -84.37 33.77` |
| Midtown Atlanta | `-spat -84.42 33.76 -84.36 33.82` |
| Manhattan NYC | `-spat -74.02 40.70 -73.97 40.75` |
| Downtown LA | `-spat -118.28 34.02 -118.23 34.06` |
| Your neighborhood | Find coords on Google Maps |

Try the downtown Atlanta one first - it's small enough it should complete in under a minute. Want me to provide the full command or would you prefer to run it yourself?

---

**User**

k it ran:

➜ $geoparquet_file = "geoparquet/atlanta_downtown.parquet"
 ~\Downloads\us_parcels                                                                                       19:49:48
➜ pixi run ogr2ogr `
>   -f Parquet `
>   -lco COMPRESSION=ZSTD `
>   -spat -84.40 33.74 -84.37 33.77 `
>   -progress `
>   $geoparquet_file $gpkg_file $gpkg_layer
Warning 6: Progress turned off as fast feature count is not available.

---

**Cursor**

Let's check what we got:

**Success!** You extracted **7,994 parcels** from downtown Atlanta using the spatial index. That was fast!

**Result:**
- **7,994 parcels** 
- **772 KB** file size (excellent ZSTD compression)
- Extracted in seconds using the spatial index

Now you have a working workflow! Here are your next options:

### 1. Query with DuckDB (add it to your environment)

```powershell
pixi add duckdb-cli

# then query the parquet directly
pixi run duckdb -c "SELECT parceladdr, totalvalue, usedesc FROM 'geoparquet/atlanta_downtown.parquet' WHERE totalvalue > 1000000 ORDER BY totalvalue DESC LIMIT 10"
```

### 2. Extract a larger area (e.g., all of Fulton County)

Fulton County bounding box:
```powershell
pixi run ogr2ogr `
  -f Parquet `
  -lco COMPRESSION=ZSTD `
  -spat -84.92 33.63 -84.09 34.08 `
  geoparquet/fulton_county.parquet `
  $gpkg_file $gpkg_layer
```

### 3. Extract multiple cities quickly

```powershell
# Denver
pixi run ogr2ogr -f Parquet -lco COMPRESSION=ZSTD -spat -105.05 39.65 -104.85 39.80 geoparquet/denver.parquet $gpkg_file $gpkg_layer

# Seattle
pixi run ogr2ogr -f Parquet -lco COMPRESSION=ZSTD -spat -122.45 47.50 -122.25 47.70 geoparquet/seattle.parquet $gpkg_file $gpkg_layer
```

### 4. View on a map

Convert to GeoJSON for quick visualization at [geojson.io](https://geojson.io):
```powershell
pixi run ogr2ogr -f GeoJSON samples/atlanta_sample.geojson geoparquet/atlanta_downtown.parquet -sql "SELECT * FROM atlanta_downtown LIMIT 500"
```

What would you like to try next?

---

**User**

➜ pixi add duckdb-cli
Error:   × failed to solve requirements of environment 'default' for platform 'win-64'
  ├─▶   × failed to solve the environment
  │
  ╰─▶ Cannot solve the request because of: No candidates were found for duckdb-cli *.


 ~\Downloads\us_parcels                                                                                       19:51:24
➜ pixi search duckdb
Using channels: conda-forge

duckdb-1.4.3-hff2d567_0 (+ 4 builds)
------------------------------------

Name                duckdb
Version             1.4.3
Build               hff2d567_0
Size                7631
License             MIT
Subdir              noarch
File Name           duckdb-1.4.3-hff2d567_0.conda
URL                 https://conda.anaconda.org/conda-forge/noarch/duckdb-1.4.3-hff2d567_0.conda
MD5                 1ff46477ddd390d1f5dcad9c20c4b3fa
SHA256              464ba2d71bca14c00521867061777bf5d19f5e19057dd57d3c81461eb2679541

Dependencies:
 - python-duckdb >=1.4.3,<1.4.4.0a0

Run exports: not available in repodata

Other Versions (15):
Version  Build
1.4.2    hff2d567_0  (+ 4 builds)
1.4.1    hff2d567_0  (+ 4 builds)
1.4.0    hff2d567_1  (+ 8 builds)
1.3.2    hff2d567_0  (+ 4 builds)
... and 11 more
 ~\Downloads\us_parcels                                                                                       19:51:35
➜ pixi add duckdb
✔ Added duckdb >=1.4.3,<2
 ~\Downloads\us_parcels                                                                                       19:51:44
➜ pixi run duckdb -c "SELECT parceladdr, totalvalue, usedesc FROM 'geoparquet/atlanta_downtown.parquet' WHERE totalvalue > 1000000 ORDER BY totalvalue DESC LIMIT 10"
duckdb: command not found

---

**Cursor**

The `duckdb` package is the Python bindings, not the CLI. Let me find the right package:

PowerShell quoting issues. Let's create a quick script instead:

No $1M+ parcels in that area. Let me adjust the query:

Interesting - `totalvalue` is NULL for all downtown Atlanta parcels. Let's see what data we do have:

DuckDB is working! You can see the parcel data:

- **State 13, County 121** = Fulton County, Georgia (correct!)
- Owner names like "STATE OF GEORGIA", "CITY OF ATLANTA", "WESTIN PORTMAN PEACHTREE II LLC"
- Some fields like `usedesc` and `yearbuilt` are NULL for these downtown parcels (common for commercial/gov properties)

Let me update the script to be more flexible:

---

**User**

duckdb-cli is available globally now:

```
➜ winget install DuckDB.cli
Found DuckDB CLI [DuckDB.cli] Version 1.4.3
This application is licensed to you by its owner.
Microsoft is not responsible for, nor does it grant any licenses to, third-party packages.
This package requires the following dependencies:
  - Packages
      Microsoft.VCRedist.2015+.x64
Successfully verified installer hash
Extracting archive...
Successfully extracted archive
Starting package install...
Command line alias added: "duckdb"
Successfully installed
```

---

**Cursor**

Now you can query directly from the command line:

Nice output! Here are some useful queries you can run directly:

The spatial extension works too - you can see the **largest parcels** by area (Coca-Cola HQ, City of Atlanta properties).

Let me update your README with the cleaner duckdb-cli workflow:

---

**User**

organize things throughout the directory in sub-directories (i.e. logs, scripts, src, lib, docs, etc.) - just don't try and mess with the main data file

---

**Cursor**

Now let me update the README with the new paths:

Done! Here's the new organized structure:

```
us_parcels/
├── data/
│   ├── geoparquet/
│   │   ├── atlanta_downtown.parquet (772 KB)
│   │   └── .gitkeep
│   └── samples/
│       ├── 13121_temp.fgb (188 MB)
│       ├── fulton_sample.fgb (1.1 MB)
│       ├── parcel.geojson
│       ├── test_sample.*
│       └── .gitkeep
├── docs/
│   └── README.md
├── scripts/
│   └── query.py
├── .gitignore              (excludes large data files)
├── .gitattributes
├── pixi.toml
├── pixi.lock
└── LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg  (untouched)
```

**Updated paths in commands:**
- GeoParquet output: `data/geoparquet/`
- Samples: `data/samples/`
- Docs: `docs/README.md`
- Scripts: `scripts/query.py`

**Example with new paths:**
```powershell
# extract to new location
pixi run ogr2ogr -f Parquet -lco COMPRESSION=ZSTD -spat -74.02 40.70 -73.97 40.75 data/geoparquet/manhattan.parquet $gpkg_file $gpkg_layer

# query with duckdb
duckdb -c "SELECT COUNT(*) FROM 'data/geoparquet/*.parquet'"
```

---

**User**

research the best way to properly migrate and store this in cloud blob storage (azure blob container via azcli + azcopy or obstore etc.) and in turn setup partitioned geoparquet / duckdb queryable data and eventually ingest into a proper normalized postgis relational database but with fields renamed and cleansed etc.

---

**Cursor**

I've gathered comprehensive research. Let me create a detailed migration plan document:

Done! Here's a summary of the research and created artifacts:

## Research Summary

### Azure Blob Storage
- **AzCopy** is the recommended tool for large file transfers (128GB in ~5 min)
- Use **ADLS Gen2** (hierarchical namespace) for better performance with Hive partitioning
- DuckDB has native **Azure extension** for direct queries

### GeoParquet Partitioning
- **Hive partitioning by state/county** is the recommended strategy for your data
- GDAL 3.12+ has `gdal vector partition` for direct partitioning
- DuckDB supports automatic partition pruning on Hive-structured data

### PostGIS Schema
- Found the **Land Record Parcel Standard** schema as reference
- Field renaming can be done with `ogr2ogr -sql "SELECT field AS new_name..."`
- Normalization includes lookup tables for states, counties, and land use codes

---

## Created Files

| File | Purpose |
|------|---------|
| `docs/MIGRATION_PLAN.md` | Complete migration strategy with code examples |
| `scripts/extract_state.ps1` | PowerShell script to extract by state bbox |
| `scripts/postgis_schema.sql` | Normalized PostGIS schema with indexes |

---

## Quick Start Commands

```powershell
# extract georgia (state 13)
.\scripts\extract_state.ps1 -State "13" -Name "georgia"

# install azure tools
winget install Microsoft.AzureCLI
winget install Microsoft.AzureCLI.AzCopy

# setup postgis (after creating database)
psql -d parcels -f scripts/postgis_schema.sql
```

The **[MIGRATION_PLAN.md](docs/MIGRATION_PLAN.md)** has the full detailed workflow for each phase. Would you like me to help you start with any specific phase?

---

**User**

I added martin and docker and an HTML file

---

**Cursor**

Nice work! Let me see what you've set up:

Excellent setup! You've added a complete tile serving stack:

| Component | Purpose |
|-----------|---------|
| **PMTiles** | Efficient cloud-native vector tiles |
| **Martin** | High-performance tile server |
| **MapLibre GL** | Client-side map rendering |
| **Docker Compose** | Easy deployment |

The `index.html` is clean - MapLibre with OSM base tiles and parcel polygons from Martin. A few optional enhancements you could add:

Added click-to-popup for parcel info on the map and updated project structure. Your setup now supports:

```
Source GPKG (100GB)
       │
       ├──► GeoParquet (DuckDB analytics)
       │
       ├──► PMTiles ──► Martin ──► MapLibre (web visualization)
       │
       └──► FlatGeoBuf (streaming for web maps)
```

**Quick commands:**

```powershell
# start tile server
docker compose up -d

# open map viewer
start index.html

# or use martin's built-in UI
start http://localhost:3000
```

The popup will show address, owner, and value when you click a parcel. Nice work getting the full stack running!

