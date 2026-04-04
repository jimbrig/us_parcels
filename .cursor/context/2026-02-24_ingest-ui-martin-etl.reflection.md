# Reflection: Ingest UI, Martin Tiles, ETL, MinIO

**Date**: 2026-02-24
**Scope**: Geospatial platform buildout—ingest API, map-based ingestion UI, Martin config, ETL pipeline, MinIO + DuckDB

## Direction Changes

- **Ingest API crash loop**: Resolved by removing `working_dir: /workspace` override in compose.yml so `main.py` is found in `/app`.
- **Python packaging**: Switched from `requirements.txt` to `pyproject.toml` with `uv`-managed deps; Dockerfile now uses uv-based build.
- **Ingest UI draw library**: Replaced broken `@mapbox/mapbox-gl-draw` with `@watergis/maplibre-gl-terradraw` for Terra Draw rectangle support.
- **Frontend tooling**: Prefer `bun`/`bunx` over npm/pnpm; initialized `package.json` with maplibre-gl, terradraw.

## Technical Details

### Ingest flow

1. Terra Draw rectangle or manual bbox on ingest map
2. Extract job → GeoParquet via ingest API
3. PostGIS load → `denver_test` layer (4,557 parcels in tested flow)
4. Styling via `config/ingest.css`

### Martin sources

| Source ID         | Type    | Notes                                  |
|-------------------|---------|----------------------------------------|
| parcels           | PostGIS | Normalized parcels (40k rows)          |
| parcel-centroids  | PostGIS | Centroids for labels                   |
| parcel-raw        | PostGIS | Raw parcel geometry                    |
| tiger-states      | PostGIS | TIGER state boundaries (SRID 4269)     |
| atlanta           | PMTiles | Sample PMTiles layer                   |

TIGER county/tract removed from Martin config—they lack spatial indexes. Need indexes before re-adding.

### nginx proxy (config/nginx.conf)

- `/tiles/` → Martin (3000)
- `/features/` → pg_featureserv (9090)
- `/tileserv/` → pg_tileserv (7800)
- `/api/` → ingest-api (8001)
- `/s3/` → MinIO (9000)

### ETL

- `scripts/etl_raw_to_parcel.sql`: `parcel_raw` → normalized `parcels.parcel` (40,369 rows)
- Deduplication: COALESCE(parcelid, parcelid2, lrid) + ROW_NUMBER
- `parcels.parcel_coverage` view added

### MinIO

- `geodata` bucket created
- GeoParquet and FlatGeoBuf samples uploaded
- `scripts/query_minio.py`: DuckDB S3 queries—run with `uv run --with duckdb scripts/query_minio.py`
- `parcels_normalized.parquet` exported from PostGIS and uploaded

## Corrections & Mistakes

- Martin source-layer names: PMTiles layer `atlanta_downtown` in container, not `lr_parcel_us`. Use actual layer names from source.
- Ingest API `working_dir` override broke container startup—paths must match Dockerfile WORKDIR.

## Unresolved Items

- [ ] pg_tileserv function-based tile sources for dynamic queries
- [ ] Spatial indexes on TIGER county/tract, then re-add to Martin
- [ ] Optional: monorepo layout (frontend vs backend vs services) when configs are stable
- [ ] Optional: stronger parcel styling (opacity/contrast) vs OSM raster

## Learned Preferences

- **Local tools for SQL**: psql, pgcli, dbmate, MCP postgres—avoid `docker exec` where possible
- **GDAL/OGR**: Document commands for extraction; Docker bind mount adds filesystem overhead on Windows
- **Fonts**: Inter TTF in `config/fonts/` for Martin-served labels; consider .gitignore or LFS if size becomes an issue

## Rule Candidates

- `.gitignore`: Added `node_modules/` for bun/npm projects (applied)
