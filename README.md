# US Parcels

Geospatial monorepo for working with 155M US parcel records from [LandRecords.us](https://landrecords.us).

## Architecture Summary

This repo uses a dual-path model:

- PostGIS is the working surface for active subsets, normalization, search, local serving, and service-backed development.
- GeoParquet, FlatGeoBuf, and PMTiles in object storage are the published artifact surface for analytics and delivery.

```text
GPKG (immutable raw input)
  ├─ subset -> PostGIS -> Martin / pg_tileserv / pg_featureserv
  └─ subset -> FGB -> GeoParquet + PMTiles -> object storage / frontend / DuckDB
```

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
| Martin | 3000 | vector tiles from PostGIS and selected PMTiles |
| pg_tileserv | 7800 | direct MVT from PostGIS |
| pg_featureserv | 9090 | OGC Features API from PostGIS |
| MinIO | 9000/9001 | local object storage for published artifacts |
| Dashboard | 8080 | nginx UI and single-origin proxy |
| ingest-api | 8001 | local ingestion service |
| TiTiler | 8000 | optional raster service |

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
