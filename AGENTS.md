# AGENTS.md

Project conventions and constraints for AI agents working in this repo.

## Source Data

- `LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` (~94GB) is the immutable raw source. Layer name: `lr_parcel_us`.
- It is gitignored. Full state bbox extracts take 30-60min due to no spatial index.
- All downstream artifacts derive from this file via `scripts/pipeline.ps1`.

## Tile Serving

Two tile servers serve different purposes:

- **Martin** (compose service, port 3000): serves MVT tiles from PostGIS tables and local PMTiles. Configured via `config/martin.yaml`. Does NOT transcode MVT to MLT. All PostGIS sources referenced in the config must exist and have spatial indexes or Martin will crash-loop.
- **tileserver-rs** (Docker, port 8082): serves PMTiles with on-the-fly MVT-to-MLT transcoding via the `.mlt` file extension on tile URLs. Configured via `config/tileserver-rs.toml` with explicit `[[sources]]` blocks. Image: `ghcr.io/vinayakkulkarni/tileserver-rs`.

MLT (MapLibre Tiles) is a columnar vector tile format supported natively by MapLibre GL JS v5.12+ and MapLibre Native. It is not a replacement for MVT — both formats are served. MLT tiles are requested by changing the tile URL extension from `.pbf` to `.mlt`.

## GDAL

- pixi provides GDAL 3.12.3+ with `libgdal-arrow-parquet` for GeoParquet/Arrow/GDALG driver support. Do NOT add `pyarrow` as a Python dep — it conflicts with libarrow versions.
- `libgdal-pg` provides the PostGIS driver. Additional driver packages: `libgdal-hdf5`, `libgdal-netcdf`, `libgdal-jp2openjpeg`, `libgdal-grib`.
- Always use `pixi run ogr2ogr` or `pixi run ogrinfo` to access the pixi-managed GDAL, not bare `ogr2ogr`.

## GDALG Pipelines

- GDALG files (`.gdalg.json`) live in `pipelines/`. They define declarative vector data pipelines.
- Always generate them via `gdal vector pipeline` CLI — do not hand-craft the JSON. The write step is stripped automatically when the output path ends in `.gdalg.json`.
- GDALG files are used as input DSNs to `ogr2ogr` for materialization: `ogr2ogr -f Parquet output.parquet pipeline.gdalg.json`.
- `/vsizip//vsicurl/` chaining reads remote ZIP archives without local download (TIGER, FEMA, etc.).

## PMTiles Source Layer Names

PMTiles layer names come from the source data layer, not the file name. Always verify with `ogrinfo -so file.pmtiles` before referencing in styles or map code. Known layer names:
- `atlanta_downtown.pmtiles` -> layer `lr_parcel_us`
- `sample/showcase/parcels.pmtiles` -> layer `showcase`

## MapLibre Styles

Layer paint/layout properties belong in MapLibre style JSON files (`config/styles/`), not inline in HTML JavaScript. Styles are tightly coupled to tile source schemas and should be version-controlled alongside tile server configuration.

## Frontend

The current frontend is single-file HTML with CDN script tags. This is a known technical debt item — the target direction is bun-managed builds with proper dependency resolution. Do not add new CDN imports; prepare for migration.

MapLibre GL JS version: 5.19.0 (align across all HTML files).

## Compose Stack

- nginx on port 8080 proxies `/tiles/` to Martin. Tiles only render correctly when accessed via `:8080`, not the bun static server on `:8081`.
- Maputnik cannot be proxied through nginx (SPA with absolute asset paths). Access directly on `:8888`.
- Profile-gated services: `ingest-api` (profile: ingest), `titiler` (profile: raster), `gdal` (profile: tools).

## Task Surface

`pixi` is the canonical task runner. `justfile` wraps pixi. `package.json` is frontend/test only.
