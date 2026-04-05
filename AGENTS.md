# AGENTS.md

Project conventions and constraints for AI agents working in this repo.

## Source Data

- `LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` (~94GB) is the immutable raw source. Layer name: `lr_parcel_us`.
- It is gitignored. Full state bbox extracts take 30-120min. The GPKG has only a spatial RTree index — no attribute indexes on `statefp` or `countyfp`. The `-spat` bbox filter IS the right approach; it uses the RTree. Combine with `-where "statefp='XX'"` to eliminate cross-border false positives at no extra cost.
- All downstream artifacts derive from this file via `scripts/pipeline.ps1`.
- Do NOT add `duckdb` as a conda pixi dep — the conda package bundles libduckdb which conflicts with `libgdal-arrow-parquet` (both embed Arrow). Use DuckDB only via `pixi run uv run --with duckdb <script>`.

## GeoParquet Artifacts

State-level artifacts live at `data/geoparquet/state=XX/parcels.parquet`:
- **WKB geometry encoding** (the GeoParquet default). Do NOT use GEOARROW — it breaks DuckDB spatial functions, freestiler, and sfarrow.
- **SORT_BY_BBOX=YES**: spatially sorted via GDAL's native temp-GPKG RTree ordering. Replaces the old two-step Hilbert sort via DuckDB.
- **WRITE_COVERING_BBOX=YES**: per-feature bbox column (`geom_bbox`) with row-group-level statistics for spatial filter pushdown.
- ZSTD compression (level 9), 50k row groups.
- Single ogr2ogr command produces the final sorted parquet — no intermediate files or DuckDB post-processing.
- Do NOT re-extract from the GPKG if a state parquet already exists.
- County-level partitions live at `data/geoparquet/state=XX/county=YYY/parcels.parquet`.

The canonical extraction command:
```
OGR_SQLITE_PRAGMA="mmap_size=107374182400,cache_size=-4194304,temp_store=MEMORY,journal_mode=OFF"
OGR_GPKG_NUM_THREADS=ALL_CPUS
GDAL_CACHEMAX=2048
ogr2ogr -f Parquet \
  -lco COMPRESSION=ZSTD -lco COMPRESSION_LEVEL=9 -lco ROW_GROUP_SIZE=50000 \
  -lco SORT_BY_BBOX=YES -lco WRITE_COVERING_BBOX=YES \
  -spat <xmin> <ymin> <xmax> <ymax> -where "statefp='XX'" \
  output.parquet source.gpkg lr_parcel_us
```

## PMTiles Pipeline

PMTiles are generated from GeoParquet via **freestiler** (Rust-powered R package).
freestiler defaults to MLT (MapLibre Tiles) format. See `scripts/generate_pmtiles.R`.

```r
# always use freestile_query() — NOT freestile_file(engine="geoparquet")
# the geoparquet engine requires FREESTILER_GEOPARQUET=true at compile time
# (absent from the Windows r-universe binary). source_crs is REQUIRED.
freestiler::freestile_query(
  query = "SELECT * FROM read_parquet('data/geoparquet/state=13/county=121/parcels.parquet')",
  output = "data/pmtiles/state=13/county=121/parcels.pmtiles",
  layer_name = "parcels", tile_format = "mlt",
  min_zoom = 12L, max_zoom = 16L, base_zoom = 16L,
  source_crs = "EPSG:4326"
)
```

**streaming = "always" also requires the Rust DuckDB backend — do NOT use on Windows.**
For state-level (7M+ features), omit streaming; freestiler loads via R DuckDB (~5min).

**Three tile artifact types:**

| Artifact | min_zoom | max_zoom | drop_rate | Size example |
|---|---|---|---|---|
| County PMTiles | 12 | 16 | none | 39-207 MB |
| State PMTiles | 10 | 16 | 2.5 | 6 GB (GA) |
| TIGER context | 0 | 12 | none | 5 MB |

## MLT Tile Serving

Martin does NOT support MLT-encoded PMTiles — it errors with "Invalid tile type".
MLT PMTiles are served as **static files through nginx** and consumed via the
**pmtiles JS protocol** (`pmtiles://` URL scheme) in MapLibre GL JS.

The MapLibre source spec MUST include `encoding: "mlt"` for MLT-encoded sources:
```json
{
  "type": "vector",
  "url": "pmtiles://http://localhost:8080/data/pmtiles/state=13/parcels.pmtiles",
  "encoding": "mlt"
}
```

Required library versions:
- MapLibre GL JS >= 5.12.0 (currently using 5.22.0)
- pmtiles.js >= 4.4.0

Martin still serves MVT tiles from PostGIS tables and MVT-encoded PMTiles (e.g. `atlanta_downtown.pmtiles`).

## GDAL

- pixi provides GDAL 3.12.3+ with `libgdal-arrow-parquet` for GeoParquet/Arrow/GDALG driver support. Do NOT add `pyarrow` as a Python dep — it conflicts with libarrow versions.
- `libgdal-pg` provides the PostGIS driver. Additional driver packages: `libgdal-hdf5`, `libgdal-netcdf`, `libgdal-jp2openjpeg`, `libgdal-grib`.
- Always use `pixi run ogr2ogr` or `pixi run ogrinfo` to access the pixi-managed GDAL, not bare `ogr2ogr`.
- GDAL ogr2ogr PMTiles driver creates stale `.tmp.mbtiles.temp.db` files that lock on crash and require manual cleanup. Do NOT use for dense parcel PMTiles — use freestiler instead.

## GDALG Pipelines

- GDALG files (`.gdalg.json`) live in `pipelines/`. They define declarative vector data pipelines.
- Always generate them via `gdal vector pipeline` CLI — do not hand-craft the JSON.
- `/vsizip//vsicurl/` chaining reads remote ZIP archives without local download (TIGER, FEMA, etc.).

## PMTiles Source Layer Names

All freestiler-generated PMTiles use `layer_name = "parcels"` or `"counties"`.
Martin-served MVT PMTiles use the original GPKG layer name:
- `atlanta_downtown.pmtiles` -> layer `lr_parcel_us`

## Frontend

- MapLibre GL JS version: **5.22.0** (required for MLT support, align across all HTML files)
- pmtiles.js version: **4.4.0** (required for MLT support)
- Single-file HTML with CDN script tags — known tech debt, target is bun-managed builds.

## Compose Stack

- nginx on port 8080 proxies `/tiles/` to Martin for MVT tiles, and serves `/data/pmtiles/` as static files for MLT PMTiles with byte-range request support.
- Martin (port 3000): MVT tiles from PostGIS + MVT PMTiles only. Does NOT support MLT.
- tileserver-rs: currently disabled (entrypoint incompatibility with config flag).
- Maputnik: access directly on `:8888` (cannot be proxied through nginx).
- Profile-gated services: `ingest-api` (profile: ingest), `titiler` (profile: raster), `gdal` (profile: tools).

## Task Surface

`pixi` is the canonical task runner. `justfile` wraps pixi. `package.json` is frontend/test only.

## R Package Stack

| Package | Role |
|---|---|
| `freestiler` | Generate MLT PMTiles from GeoParquet via DuckDB query |
| `pmtiles` | Inspect (`pm_show`), view (`pm_view`), upload to R2 (`pm_upload`) |
| `mapgl` | Compose multi-layer MapLibre maps in R |
| `sfarrow` | Read parquets as sf (`st_read_parquet`) |
| `duckdb` (R) | SQL queries across Hive-partitioned parquets |

## targets Pipeline

`_targets.R` defines a reproducible pipeline: GPKG → raw Parquet → Hilbert sort → county partition → PMTiles. Uses crew for parallel workers. GPKG extraction runs sequentially (single SQLite reader); all other steps run in parallel across states.
