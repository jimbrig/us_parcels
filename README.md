# US Parcels

Geospatial monorepo for working with 155M US parcel records from [LandRecords.us](https://landrecords.us).

## Architecture Summary

Dual-path model: PostGIS as relational working surface, cloud-native artifacts for analytics and tile delivery.

```text
GPKG (94GB, immutable raw input)
  ├─ ogr2ogr -spat -where -> Hilbert GeoParquet (state + county Hive partitions)
  │                            ├─ freestiler -> MLT PMTiles (state z10-16, county z12-16)
  │                            ├─ DuckDB analytics (hive_partitioning=true)
  │                            └─ R/sfarrow/arrow (county-level sf objects)
  ├─ PostGIS -> Martin (MVT) / pg_featureserv (OGC API Features)
  └─ TIGER GDALG -> county boundary GeoParquet + PMTiles (z0-12 context)
```

Pipeline stages:
1. **GPKG -> raw Parquet**: `ogr2ogr -spat -where statefp` with mmap pragma, ALL_CPUS threads
2. **Hilbert sort**: DuckDB `ST_Hilbert(centroidx, centroidy)` ordering for bbox-efficient row groups
3. **County partition**: DuckDB parallel writes to `state=XX/county=YYY/parcels.parquet`
4. **PMTiles**: `freestiler::freestile_query()` generates MLT-encoded tiles (Rust engine, DuckDB input)
5. **Serving**: nginx serves MLT PMTiles as static files; Martin serves MVT from PostGIS/MVT PMTiles

Completed: Georgia (6.96M parcels, 159 counties), North Carolina (5.76M parcels, 100 counties).

For the authoritative version of that model, see:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/ADR/0001-system-of-record.md](docs/ADR/0001-system-of-record.md)
- [docs/DATA_CONTRACT.md](docs/DATA_CONTRACT.md)

## Documentation Precedence

Use docs in this order:

1. `docs/ADR/`
2. `docs/ARCHITECTURE.md`
3. `docs/DATA_CONTRACT.md` and `docs/RUNBOOK.md`
4. `README.md`
5. `docs/chats/` as non-normative reference material

## Task Surface

- `pixi` is the canonical repo task surface.
- `just` is a thin convenience wrapper around `pixi`.
- `package.json` is reserved for frontend and Playwright tasks.

Common commands:

```powershell
pixi run up
pixi run showcase
pixi run query-minio
pixi run verify-map
pixi run check
```

Full command guidance lives in [docs/TASKS.md](docs/TASKS.md).

## Quick Start

```powershell
git clone https://github.com/jimbrig/us_parcels.git
cd us_parcels
cp .env.example .env

pixi install
bun install

pixi run up
pixi run status
```

## Core Services

| Service | Port | Purpose |
|---------|------|---------|
| PostGIS | 5432 | relational working surface for loaded subsets |
| Martin | 3000 | MVT vector tiles from PostGIS tables and PMTiles |
| tileserver-rs | 8082 | MLT vector tiles from PMTiles (MVT-to-MLT transcoding) |
| pg_featureserv | 9090 | OGC API Features from PostGIS |
| pg_tileserv | 7800 | direct MVT from PostGIS |
| MinIO | 9000/9001 | local object storage for published artifacts |
| Maputnik | 8888 | MapLibre style editor (direct access, not proxied) |
| Dashboard | 8080 | nginx UI and single-origin proxy |
| ingest-api | 8001 | local ingestion service (profile: ingest) |
| TiTiler | 8000 | optional raster COG service (profile: raster) |

## Common Workflows

### bring up the stack

```powershell
pixi run up
pixi run up-ingest
pixi run up-dev
```

### run the minimal showcase

```powershell
pixi run showcase
pixi run serve-map
pixi run verify-map
```

### work with the pipeline

```powershell
pixi run pipeline -- -Action status
pixi run pipeline -- -Action cloud-state -State 13 -Name georgia
pixi run pipeline -- -Action upload-minio -State 13
```

### query published artifacts

```powershell
pixi run query-minio
```

## Storage Conventions

Canonical published artifact layout:

```text
data/
  flatgeobuf/state=13/parcels.fgb
  geoparquet/state=13/parcels.parquet
  pmtiles/state=13/parcels.pmtiles
```

Canonical object storage layout:

```text
s3://geodata/parcels/state=13/parcels.fgb
s3://geodata/parcels/state=13/parcels.parquet
s3://geodata/parcels/state=13/parcels.pmtiles
```

## Connection Points

| Context | Value |
|---------|-------|
| psql | `psql -h localhost -p 5432 -U parcels -d parcels` |
| host URI | `postgresql://parcels:parcels@localhost:5432/parcels` |
| docker URI | `postgresql://parcels:parcels@postgis:5432/parcels` |
| MinIO API | `http://localhost:9000` |
| MinIO console | `http://localhost:9001` |

## Additional Docs

- [docs/FORMATS.md](docs/FORMATS.md)
- [docs/CLOUD_NATIVE_PIPELINE_SPEC.md](docs/CLOUD_NATIVE_PIPELINE_SPEC.md)
- [docs/MIGRATION_PLAN.md](docs/MIGRATION_PLAN.md)
- [docs/VISUAL_VERIFICATION.md](docs/VISUAL_VERIFICATION.md)
- [docs/ROADMAP.md](docs/ROADMAP.md)
