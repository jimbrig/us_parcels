# US Parcels

155 million US parcel records from [LandRecords.us](https://landrecords.us), served through a Docker-based geospatial stack with PostGIS as the central store.

## Architecture

```
Source GPKG (155M parcels)
    |
    |  ogr2ogr -spat / -where  (extract by state, county, or bbox)
    v
 PostGIS  <-- central store, single source of truth
    |
    |--- Martin (:3000)         vector tiles from tables + PMTiles files
    |--- pg_tileserv (:7800)    MVT tiles from tables & SQL functions
    |--- pg_featureserv (:9000) OGC Features API (GeoJSON)
    |
    |  ogr2ogr / DuckDB  (export derivatives from PostGIS)
    v
 GeoParquet   analytics, DuckDB/pandas/Arrow queries
 PMTiles      static vector tile hosting (CDN/S3)
 FlatGeoBuf   HTTP range-request serving
```

PostGIS is the single source of truth. All tile and feature servers auto-discover tables loaded into PostGIS. Derivative formats (GeoParquet, PMTiles, FlatGeoBuf) are exported from PostGIS for specific use cases like static hosting or analytics.

## Directory Structure

```
us_parcels/
├── assets/                       # screenshots, images
├── data/
│   ├── flatgeobuf/               # FlatGeoBuf exports
│   ├── geoparquet/               # GeoParquet exports
│   ├── pmtiles/                  # PMTiles for static tile serving
│   └── samples/                  # test samples
├── docs/
│   └── MIGRATION_PLAN.md         # cloud migration strategy
├── scripts/
│   ├── extract_state.ps1         # extract single state by bbox
│   ├── ingest.sh                 # bash ingest for Docker GDAL container
│   ├── ingest_postgis.ps1        # PowerShell ingest wrapper
│   ├── pipeline.ps1              # unified extract -> load -> export
│   ├── postgis_schema.sql        # normalized PostGIS schema
│   └── query.py                  # DuckDB query helper
├── compose.yml                   # docker compose (full service stack)
├── .env                          # environment variables
├── index.html                    # services dashboard
├── map.html                      # full-screen MapLibre viewer
├── pixi.toml                     # conda dependencies & tasks
└── LR_PARCEL_NATIONWIDE_*.gpkg   # source data (155M parcels, not tracked)
```

## Quick Start

### Prerequisites

- [Docker Desktop](https://docs.docker.com/desktop/)
- [Pixi](https://pixi.sh) (for local GDAL/DuckDB tools)

### 1. Start the Stack

```powershell
# start PostGIS + Martin + pg_tileserv + pg_featureserv
docker compose up -d

# verify all services are healthy
docker compose ps
```

PostGIS initializes with the parcels schema on first start (tables, indexes, views, search functions). Martin, pg_tileserv, and pg_featureserv auto-discover all PostGIS tables.

### 2. Extract & Load Data

The `pipeline.ps1` script handles the full workflow. Extract from the monolithic GPKG, load into PostGIS, and optionally export derivative formats:

```powershell
# full pipeline: extract state -> load into PostGIS -> export PMTiles + FlatGeoBuf
.\scripts\pipeline.ps1 -Action full -State "13" -Name "georgia"

# extract just a bounding box
.\scripts\pipeline.ps1 -Action extract-bbox -Bbox "-84.40,33.74,-84.37,33.77" -Name "atlanta_dt"

# load an existing file into PostGIS
.\scripts\pipeline.ps1 -Action load -Source data/geoparquet/atlanta_downtown.parquet

# export from PostGIS to derivative formats
.\scripts\pipeline.ps1 -Action export -Format pmtiles -Name "atlanta_parcels"

# check what's loaded
.\scripts\pipeline.ps1 -Action status
```

### 3. Open the Dashboard

Open `index.html` in a browser (serve it via HTTP for full functionality):

```powershell
python -m http.server 8080
start http://localhost:8080
```

The dashboard shows:
- Service health status with links to each UI
- Interactive map preview (switch between PMTiles and PostGIS sources)
- Architecture diagram
- PostGIS table status (row counts, extents)
- Connection strings

## Services

| Service | Port | Purpose | URL |
|---------|------|---------|-----|
| **PostGIS** | 5432 | Central spatial database (PostgreSQL 17 + PostGIS 3.5) | `psql -h localhost -U parcels -d parcels` |
| **Martin** | 3000 | Vector tiles from PostGIS + PMTiles files | http://localhost:3000 |
| **pg_tileserv** | 7800 | MVT tiles from PostGIS tables and SQL functions | http://localhost:7800 |
| **pg_featureserv** | 9000 | OGC Features API (GeoJSON, filtering, spatial queries) | http://localhost:9000 |
| **TiTiler** | 8000 | Dynamic raster COG tile server (opt-in profile) | http://localhost:8000 |

### Docker Profiles

```powershell
# core stack (default): postgis, martin, pg_tileserv, pg_featureserv
docker compose up -d

# include raster tile server
docker compose --profile raster up -d

# run GDAL container for ingestion
docker compose --profile tools run --rm gdal ogr2ogr ...
```

## Data Pipeline

### Extraction from Source GPKG

The GPKG has a spatial index. Use `-spat` (bounding box) for fast extraction:

```powershell
$gpkg = "LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"

# extract by bounding box (seconds for city-scale)
pixi run ogr2ogr -f Parquet -lco COMPRESSION=ZSTD `
  -spat -84.40 33.74 -84.37 33.77 `
  data/geoparquet/atlanta_downtown.parquet $gpkg lr_parcel_us

# extract by attribute filter
pixi run ogr2ogr -f Parquet -lco COMPRESSION=ZSTD `
  -where "statefp = '13' AND countyfp = '121'" `
  data/geoparquet/fulton_county.parquet $gpkg lr_parcel_us
```

### Loading into PostGIS

PostGIS is the central store. Load data via the Docker GDAL container:

```powershell
# via pipeline script (recommended)
.\scripts\pipeline.ps1 -Action load -Source data/geoparquet/atlanta_downtown.parquet

# via docker directly
docker compose --profile tools run --rm gdal ogr2ogr `
  -f PostgreSQL "PG:host=postgis dbname=parcels user=parcels password=parcels" `
  data/geoparquet/atlanta_downtown.parquet `
  -nln parcels.parcel_raw -append -progress --config PG_USE_COPY YES

# build spatial index after bulk loading
docker compose exec postgis psql -U parcels -d parcels `
  -c "CREATE INDEX IF NOT EXISTS idx_parcel_raw_geom ON parcels.parcel_raw USING gist(geom);"
```

### Exporting Derivative Formats

Export from PostGIS to formats optimized for specific use cases:

```powershell
# GeoParquet (analytics with DuckDB/pandas/Arrow)
docker compose --profile tools run --rm gdal ogr2ogr `
  -f Parquet -lco COMPRESSION=ZSTD -lco GEOMETRY_ENCODING=GEOARROW `
  data/geoparquet/export.parquet `
  "PG:host=postgis dbname=parcels user=parcels password=parcels" parcels.parcel_raw

# PMTiles (static vector tile hosting)
docker compose --profile tools run --rm gdal ogr2ogr `
  -f PMTiles -dsco MINZOOM=12 -dsco MAXZOOM=16 `
  data/pmtiles/export.pmtiles `
  "PG:host=postgis dbname=parcels user=parcels password=parcels" parcels.parcel_raw

# FlatGeoBuf (HTTP range-request serving)
docker compose --profile tools run --rm gdal ogr2ogr `
  -f FlatGeoBuf `
  data/flatgeobuf/export.fgb `
  "PG:host=postgis dbname=parcels user=parcels password=parcels" parcels.parcel_raw
```

## Serving Methods Compared

| Method | Format | Best For | Pros | Cons |
|--------|--------|----------|------|------|
| **Martin + PostGIS** | MVT | Interactive web maps with live data | Real-time, auto-discovers tables, supports SQL functions | Requires running PostGIS |
| **Martin + PMTiles** | MVT | Static tile hosting, CDN delivery | No database needed, fast, cacheable | Requires rebuild for updates |
| **pg_tileserv** | MVT | PostGIS-native tile serving | Auto-discovers, supports parameterized SQL functions as tile sources | PostGIS only |
| **pg_featureserv** | GeoJSON | Feature queries, OGC API compliance | Filtering, spatial queries, pagination | Not suited for rendering millions of features |
| **FlatGeoBuf** | FGB | Direct browser consumption via HTTP range requests | No server needed, spatial filtering built-in | No styling, client does all rendering |
| **GeoParquet** | Parquet | Bulk analytics with DuckDB/pandas/Spark | Columnar compression, fast aggregations | Not directly renderable in browsers |

## Querying

### PostGIS (SQL)

```sql
-- top parcels by assessed value
SELECT parceladdr, ownername, totalvalue
FROM parcels.parcel_raw
WHERE totalvalue IS NOT NULL
ORDER BY totalvalue DESC LIMIT 10;

-- parcels within a bounding box
SELECT parceladdr, ownername, ST_Area(ST_Transform(geom, 32616)) as area_sqm
FROM parcels.parcel_raw
WHERE geom && ST_MakeEnvelope(-84.40, 33.74, -84.37, 33.77, 4326)
ORDER BY area_sqm DESC LIMIT 10;

-- search by owner name (uses trigram index)
SELECT * FROM parcels.search_by_owner('COCA COLA');

-- search by address
SELECT * FROM parcels.search_by_address('PEACHTREE');
```

### DuckDB (GeoParquet)

```powershell
# query parquet files directly
duckdb -c "SELECT parceladdr, ownername FROM 'data/geoparquet/*.parquet' LIMIT 10"

# spatial query with DuckDB
duckdb -c "
  INSTALL spatial; LOAD spatial;
  SELECT parceladdr, ownername,
    ST_Area(ST_Transform(geom, 'EPSG:4326', 'EPSG:32616')) as area_sqm
  FROM 'data/geoparquet/atlanta_downtown.parquet'
  ORDER BY area_sqm DESC LIMIT 5
"

# aggregate across all loaded states
duckdb -c "SELECT statefp, countyfp, COUNT(*) FROM 'data/geoparquet/*.parquet' GROUP BY ALL"
```

### pg_featureserv (HTTP API)

```powershell
# list collections
curl http://localhost:9000/collections.json

# get features as GeoJSON (with limit and bbox filter)
curl "http://localhost:9000/collections/parcels.parcel_raw/items.json?limit=10&bbox=-84.39,33.75,-84.38,33.76"

# call a SQL function
curl "http://localhost:9000/functions/parcels.search_by_address/items.json?search_term=PEACHTREE&limit=5"
```

## PostGIS Tuning

The compose file starts PostgreSQL with parameters tuned for spatial bulk workloads:

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `shared_buffers` | 512MB | In-memory page cache |
| `work_mem` | 64MB | Per-operation sort/hash memory |
| `maintenance_work_mem` | 1GB | Fast index builds and VACUUM |
| `effective_cache_size` | 2GB | Planner hint for OS cache |
| `max_wal_size` | 4GB | Fewer checkpoints during bulk loads |
| `random_page_cost` | 1.1 | SSD-optimized planner cost |
| `max_parallel_workers_per_gather` | 4 | Parallel spatial queries |

For initial bulk loads of millions of records, also consider running `ANALYZE` after loading:

```sql
ANALYZE parcels.parcel_raw;
```

## Connection Strings

| Context | Connection String |
|---------|-------------------|
| From host | `postgresql://parcels:parcels@localhost:5432/parcels` |
| Docker network | `postgresql://parcels:parcels@postgis:5432/parcels` |
| psql | `psql -h localhost -p 5432 -U parcels -d parcels` |
| Cursor MCP | Configured in `.cursor/mcp.json` |

## Pixi Tasks

```powershell
pixi run up        # docker compose up -d
pixi run down      # docker compose down
pixi run logs      # docker compose logs -f
pixi run status    # docker compose ps
pixi run psql      # connect to PostGIS
pixi run index     # build spatial index on parcel_raw
pixi run reset-db  # wipe PostGIS volume and reinitialize
```

## Schema Reference

| Field | Type | Description |
|-------|------|-------------|
| `parcelid` | String | Primary parcel identifier |
| `geoid` | String | Combined state+county FIPS |
| `statefp` | String | State FIPS code (e.g., "13" = Georgia) |
| `countyfp` | String | County FIPS code (e.g., "121" = Fulton) |
| `parceladdr` | String | Parcel address |
| `ownername` | String | Property owner name |
| `totalvalue` | Integer64 | Total assessed value |
| `yearbuilt` | Integer | Year structure built |
| `usedesc` | String | Land use description |
| `geom` | MultiPolygon | Parcel geometry (WGS 84) |
