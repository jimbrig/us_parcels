# US Parcels

Geospatial data platform for 155 million US parcel records from [LandRecords.us](https://landrecords.us).

Two goals:
1. **Data extraction** -- efficiently break down the monolithic 155M-record GPKG into usable, cloud-native formats (GeoParquet, PMTiles, FlatGeoBuf) and a centralized PostGIS store
2. **Tooling showcase** -- demonstrate modern geospatial infrastructure (tile servers, feature APIs, object storage, DuckDB analytics) using real data

## Architecture

```
Source GPKG (155M parcels, local disk)
    |
    |  ogr2ogr -spat / -where  (extract by state, county, or bbox)
    v
PostGIS (:5432)  <-- central query store
    |
    |--- Martin (:3000)         vector tiles from tables + PMTiles files
    |--- pg_tileserv (:7800)    MVT tiles from tables & SQL functions
    |--- pg_featureserv (:9090) OGC Features API (GeoJSON)
    |
    |  ogr2ogr / DuckDB  (export derivatives)
    v
MinIO S3 (:9000)  local object storage
    |
    +-- GeoParquet   analytics via DuckDB/pandas/Arrow
    +-- PMTiles      static vector tile hosting (CDN/S3)
    +-- FlatGeoBuf   HTTP range-request serving
```

## Quick Start

```powershell
# clone
git clone https://github.com/jimbrig/us_parcels.git
cd us_parcels

# copy environment file
cp .env.example .env

# start the stack
docker compose up -d

# verify
docker compose ps
```

## Services

| Service | Port | Purpose |
|---------|------|---------|
| **PostGIS** | 5432 | PostgreSQL 17 + PostGIS 3.5, tuned for spatial workloads |
| **Martin** | 3000 | Vector tiles from PostGIS tables + PMTiles files |
| **pg_tileserv** | 7800 | MVT tiles from PostGIS tables and SQL functions |
| **pg_featureserv** | 9090 | OGC API Features (GeoJSON, filtering, spatial queries) |
| **MinIO** | 9000/9001 | S3-compatible object storage (API / web console) |
| **Dashboard** | 8080 | nginx serving index.html with service health + map preview |
| **TiTiler** | 8000 | Dynamic raster COG tile server (profile: `raster`) |
| **GDAL** | -- | On-demand ingestion container (profile: `tools`) |

### Docker Profiles

```powershell
docker compose up -d                              # core stack
docker compose --profile raster up -d             # + TiTiler
docker compose --profile tools run --rm gdal ...  # GDAL one-shot
```

## Data Pipeline

### Extract from Source GPKG

```powershell
# by bounding box (fast, uses spatial index)
pixi run ogr2ogr -f Parquet -lco COMPRESSION=ZSTD `
  -spat -84.40 33.74 -84.37 33.77 `
  data/geoparquet/atlanta.parquet $gpkg lr_parcel_us

# by attribute filter (exact but slower)
pixi run ogr2ogr -f Parquet -lco COMPRESSION=ZSTD `
  -where "statefp = '08'" `
  data/geoparquet/colorado.parquet $gpkg lr_parcel_us

# full pipeline: extract -> PostGIS -> export derivatives
.\scripts\pipeline.ps1 -Action full -State "08" -Name "colorado"
```

### Load into PostGIS

```powershell
docker compose --profile tools run --rm gdal ogr2ogr `
  -f PostgreSQL "PG:host=postgis dbname=parcels user=parcels password=parcels" `
  data/geoparquet/colorado.parquet `
  -nln parcels.parcel_raw -append -progress --config PG_USE_COPY YES
```

### Query with DuckDB (MinIO S3)

```sql
SET s3_endpoint = 'localhost:9000';
SET s3_access_key_id = 'minioadmin';
SET s3_secret_access_key = 'minioadmin';
SET s3_use_ssl = false;
SET s3_url_style = 'path';

SELECT statefp, COUNT(*) as parcels
FROM read_parquet('s3://geodata/parcels/raw/**/*.parquet', hive_partitioning=true)
GROUP BY statefp ORDER BY parcels DESC;
```

## Attribute Coverage

Coverage varies wildly by county assessor. The parcel geometry + ID + owner + address are universal. Everything else is county-dependent:

| Field | CO (Denver) | TX (Dallas) | NY (Manhattan) | GA (Atlanta) |
|-------|-------------|-------------|----------------|--------------|
| address | 99% | 96% | 98% | 99% |
| owner | 100% | 100% | 100% | 100% |
| totalvalue | 98% | 100% | 90% | 0% |
| yearbuilt | 80% | 0% | 90% | 0% |
| usedesc | 100% | 0% | 6% | 0% |
| saleamt | 93% | 0% | 0% | 0% |

## Connection Strings

| Context | Value |
|---------|-------|
| Host (psql) | `psql -h localhost -p 5432 -U parcels -d parcels` |
| Host (URI) | `postgresql://parcels:parcels@localhost:5432/parcels` |
| Docker network | `postgresql://parcels:parcels@postgis:5432/parcels` |
| MinIO S3 | `http://localhost:9000` (user: minioadmin) |
| MinIO Console | `http://localhost:9001` |

## Documentation

- **[docs/FORMATS.md](docs/FORMATS.md)** -- comprehensive reference for all geospatial formats, tile specifications (MVT, MLT, PMTiles), serving methods, and enrichment data sources
- **[docs/MIGRATION_PLAN.md](docs/MIGRATION_PLAN.md)** -- cloud migration strategy (Azure Blob, hive-partitioned GeoParquet, DuckDB cloud queries)

## Enrichment Roadmap

| Priority | Source | Value | Status |
|----------|--------|-------|--------|
| 1 | Census ACS block groups | Income, demographics, housing tenure | Planned |
| 2 | FEMA NFHL flood zones | Flood risk per parcel | Planned |
| 3 | Overture Maps buildings | Building footprints, coverage ratio | Planned |
| 4 | SSURGO soils | Drainage, buildability, farmland class | Planned |
| 5 | NWI wetlands | Development constraints | Planned |
| 6 | USGS 3DEP elevation | Slope, terrain, viewshed | Planned |
| 7 | RealEstateAPI | AVM, tax, mortgage, comps (targeted) | Available |

## Schema Reference

| Field | Type | Description |
|-------|------|-------------|
| `parcelid` | String | Primary parcel identifier |
| `geoid` | String | Combined state+county FIPS |
| `statefp` | String | State FIPS code |
| `countyfp` | String | County FIPS code |
| `parceladdr` | String | Parcel address |
| `ownername` | String | Property owner name |
| `totalvalue` | Integer64 | Total assessed value |
| `yearbuilt` | Integer | Year structure built |
| `usedesc` | String | Land use description |
| `geom` | MultiPolygon | Parcel geometry (WGS 84) |
