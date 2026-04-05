# R/pipeline_functions.R
#
# functions used by the targets pipeline (_targets.R).
# each function is a single pure step: one input set -> one output path.
# targets tracks changes via file hashes on the returned paths.

# ---- constants --------------------------------------------------------------

STATE_BOUNDS <- list(
  "01" = c(-88.47, 30.22, -84.89, 35.01),  # Alabama
  "04" = c(-114.82, 31.33, -109.04, 37.00), # Arizona
  "05" = c(-94.62, 33.00, -89.64, 36.50),   # Arkansas
  "06" = c(-124.48, 32.53, -114.13, 42.01), # California
  "08" = c(-109.06, 36.99, -102.04, 41.00), # Colorado
  "09" = c(-73.73, 40.95, -71.79, 42.05),   # Connecticut
  "10" = c(-75.79, 38.45, -75.05, 39.84),   # Delaware
  "11" = c(-77.12, 38.79, -76.91, 38.99),   # DC
  "12" = c(-87.63, 24.52, -80.03, 31.00),   # Florida
  "13" = c(-85.61, 30.36, -80.84, 35.00),   # Georgia
  "16" = c(-117.24, 41.99, -111.04, 49.00), # Idaho
  "17" = c(-91.51, 36.97, -87.50, 42.51),   # Illinois
  "18" = c(-88.10, 37.77, -84.78, 41.76),   # Indiana
  "19" = c(-96.64, 40.38, -90.14, 43.50),   # Iowa
  "20" = c(-102.05, 36.99, -94.59, 40.00),  # Kansas
  "21" = c(-89.57, 36.50, -81.96, 39.15),   # Kentucky
  "22" = c(-94.04, 28.93, -88.82, 33.02),   # Louisiana
  "24" = c(-79.49, 37.91, -75.05, 39.72),   # Maryland
  "25" = c(-73.51, 41.24, -69.93, 42.89),   # Massachusetts
  "26" = c(-90.42, 41.70, -82.41, 48.19),   # Michigan
  "27" = c(-97.24, 43.50, -89.49, 49.38),   # Minnesota
  "29" = c(-95.77, 35.99, -89.10, 40.61),   # Missouri
  "34" = c(-75.56, 38.93, -73.89, 41.36),   # New Jersey
  "36" = c(-79.76, 40.50, -71.86, 45.02),   # New York
  "37" = c(-84.32, 33.84, -75.46, 36.59),   # North Carolina
  "39" = c(-84.82, 38.40, -80.52, 42.33),   # Ohio
  "42" = c(-80.52, 39.72, -74.69, 42.27),   # Pennsylvania
  "47" = c(-90.31, 34.98, -81.65, 36.68),   # Tennessee
  "48" = c(-106.65, 25.84, -93.51, 36.50),  # Texas
  "51" = c(-83.68, 36.54, -75.24, 39.47),   # Virginia
  "53" = c(-124.85, 45.54, -116.92, 49.00)  # Washington
)

GPKG_FILE  <- "LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"
GPKG_LAYER <- "lr_parcel_us"

# ---- step 1: extract state parquet from GPKG --------------------------------
#
# runs pixi-managed ogr2ogr with:
#   -spat   : RTree spatial pre-filter (uses GPKG spatial index)
#   -where  : attribute filter on statefp (eliminates cross-border features,
#             applied to spatial-index candidates only — no full table scan)
#   -lco COMPRESSION=ZSTD, GEOMETRY_ENCODING=GEOARROW, ROW_GROUP_SIZE=50000
#   env vars: OGR_SQLITE_PRAGMA (mmap + large cache), OGR_GPKG_NUM_THREADS
#
# output: data/geoparquet/state=XX/parcels_raw.parquet  (unsorted)
# the hilbert sort runs as a separate step to allow re-sorting without re-extraction.
#
extract_state_parquet <- function(state_fips, gpkg = GPKG_FILE, layer = GPKG_LAYER) {
  bb  <- STATE_BOUNDS[[state_fips]]
  if (is.null(bb)) cli::cli_abort("unknown state FIPS: {state_fips}")
  if (!file.exists(gpkg)) cli::cli_abort("GPKG not found: {gpkg}")

  out_dir  <- file.path("data", "geoparquet", paste0("state=", state_fips))
  out_path <- file.path(out_dir, "parcels_raw.parquet")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  # exact ogr2ogr command (printed for transparency):
  args <- c(
    "-f", "Parquet",
    "-lco", "COMPRESSION=ZSTD",
    "-lco", "GEOMETRY_ENCODING=GEOARROW",
    "-lco", "ROW_GROUP_SIZE=50000",
    "-spat", bb[1], bb[2], bb[3], bb[4],
    "-where", sprintf("statefp='%s'", state_fips),
    "-progress",
    out_path, gpkg, layer
  )
  cli::cli_alert_info("state={state_fips}: pixi run ogr2ogr {paste(args, collapse=' ')}")

  withr::with_envvar(
    c(
      OGR_SQLITE_PRAGMA   = "mmap_size=107374182400,cache_size=-4194304,temp_store=MEMORY",
      OGR_GPKG_NUM_THREADS = "ALL_CPUS",
      GDAL_CACHEMAX        = "2048"
    ),
    code = {
      rc <- processx::run(
        "pixi", c("run", "ogr2ogr", args),
        echo = TRUE, error_on_status = FALSE
      )
      if (rc$status != 0L) {
        cli::cli_abort("ogr2ogr failed for state={state_fips} (exit {rc$status})")
      }
    }
  )

  cli::cli_alert_success("state={state_fips}: wrote {out_path}")
  out_path
}

# ---- step 2: hilbert-sort raw parquet ---------------------------------------
#
# reads the unsorted parcels_raw.parquet and writes a hilbert-ordered parcels.parquet.
# DuckDB reads the raw parquet, applies ST_Hilbert ordering, writes ZSTD parquet.
#
# exact DuckDB query:
#   COPY (SELECT * FROM read_parquet('<raw>') ORDER BY ST_Hilbert(geom, ST_Extent(...)))
#   TO '<out>' (FORMAT parquet, COMPRESSION zstd, COMPRESSION_LEVEL 3, ROW_GROUP_SIZE 50000)
#
hilbert_sort_parquet <- function(raw_path, state_fips) {
  out_path <- file.path(dirname(raw_path), "parcels.parquet")

  args <- c(
    "--with", "duckdb",
    "scripts/to_hilbert_parquet.py",
    raw_path, out_path,
    "--state", state_fips
  )
  cli::cli_alert_info("state={state_fips}: pixi run uv run {paste(args, collapse=' ')}")

  rc <- processx::run("pixi", c("run", "uv", "run", args), echo = TRUE, error_on_status = FALSE)
  if (rc$status != 0L) cli::cli_abort("hilbert sort failed for state={state_fips}")

  # remove the unsorted intermediate
  file.remove(raw_path)
  cli::cli_alert_success("state={state_fips}: hilbert parquet -> {out_path}")
  out_path
}

# ---- step 3: partition by county (optional) ---------------------------------
#
# reads the hilbert-sorted state parquet and writes per-county parquets.
# a single DuckDB table scan computes all county bounds, then threads write each county.
#
# output: data/geoparquet/state=XX/county=YYY/parcels.parquet (hive-partitioned)
#
# this step is OPTIONAL for CONUS. reasons to include:
#   - selective county downloads from blob storage without full-state fetch
#   - incremental re-tiling (only changed counties need new PMTiles)
#   - county-level API responses
#   - enables read_parquet(..., hive_partitioning=true) with county= filter pushdown
#
partition_by_county <- function(state_parquet_path, state_fips, parallelism = 4L) {
  args <- c(
    "--with", "duckdb",
    "scripts/partition_by_county.py",
    "--state", state_fips,
    "--parallelism", as.character(parallelism)
  )
  cli::cli_alert_info("state={state_fips}: pixi run uv run {paste(args, collapse=' ')}")

  rc <- processx::run("pixi", c("run", "uv", "run", args), echo = TRUE, error_on_status = FALSE)
  if (rc$status != 0L) cli::cli_abort("county partition failed for state={state_fips}")

  county_dir <- file.path("data", "geoparquet", paste0("state=", state_fips))
  county_files <- list.files(county_dir, pattern = "parcels\\.parquet",
                             recursive = TRUE, full.names = TRUE)
  county_files <- county_files[grepl("county=", county_files)]
  cli::cli_alert_success("state={state_fips}: {length(county_files)} county parquets")
  county_files
}

# ---- step 4a: state-level PMTiles ------------------------------------------
#
# uses freestile_query() with DuckDB streaming — the 1-2GB state parquet never enters R.
#
# exact DuckDB query:
#   SELECT * FROM read_parquet('<state_parquet>')
#
# zoom strategy for parcel polygons:
#   min_zoom = 12: first visible at neighbourhood/street level
#   max_zoom = 16: full polygon resolution at building scale
#   base_zoom = 16: guarantees all features at z16 (thinning reference)
#   no drop_rate: parcels are exhaustive coverage — dropping creates gaps
#
tile_state_pmtiles <- function(state_parquet_path, state_fips) {
  out_dir  <- file.path("data", "pmtiles", paste0("state=", state_fips))
  out_path <- file.path(out_dir, "parcels.pmtiles")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  sz_mb <- round(file.size(state_parquet_path) / 1e6)
  cli::cli_alert_info(
    "state={state_fips}: tiling {state_parquet_path} ({sz_mb} MB) -> {out_path}"
  )
  cli::cli_alert_info("  freestile_query: SELECT * FROM read_parquet('{state_parquet_path}')")
  cli::cli_alert_info("  format=MLT | zoom=12-16 | streaming=always")

  freestiler::freestile_query(
    query      = sprintf("SELECT * FROM read_parquet('%s')",
                         normalizePath(state_parquet_path, winslash = "/")),
    output     = out_path,
    layer_name = "parcels",
    tile_format = "mlt",
    min_zoom   = 10L,   # first visible at z10 with ~0.07% of features
    max_zoom   = 16L,
    base_zoom  = 16L,   # 100% of features at z16, halved per zoom below
    drop_rate  = 2.5,   # z15=29% z14=8% z13=2% z12=0.7% z10=0.07%
    source_crs = "EPSG:4326",
    streaming  = "always",
    overwrite  = TRUE
  )

  cli::cli_alert_success("state={state_fips}: {out_path} ({round(file.size(out_path)/1e6,1)} MB)")
  out_path
}

# ---- step 4b: county-level PMTiles (optional) -------------------------------
#
# uses freestile_query() — reads parquet via DuckDB SQL, never loads into R.
#
# freestile_file(engine="geoparquet") requires FREESTILER_GEOPARQUET=true at
# compile time, absent from the Windows r-universe binary. freestile_query()
# with read_parquet() works on all platforms via R's DuckDB package.
#
# exact DuckDB query:
#   SELECT * FROM read_parquet('<county_parquet_path>')
#
tile_county_pmtiles <- function(county_parquet_path) {
  parts       <- strsplit(normalizePath(county_parquet_path, winslash = "/"), "/")[[1L]]
  state_dir   <- parts[grep("^state=", parts)]
  cty_dir     <- parts[grep("^county=", parts)]
  county_fips <- sub("county=", "", cty_dir)

  out_dir  <- file.path("data", "pmtiles", state_dir, cty_dir)
  out_path <- file.path(out_dir, "parcels.pmtiles")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  src   <- normalizePath(county_parquet_path, winslash = "/")
  sz_mb <- round(file.size(src) / 1e6, 1)
  cli::cli_alert_info(
    "county={county_fips}: SELECT * FROM read_parquet('{src}') ({sz_mb} MB)"
  )

  freestiler::freestile_query(
    query      = sprintf("SELECT * FROM read_parquet('%s')", src),
    output     = out_path,
    layer_name = "parcels",
    tile_format = "mlt",
    min_zoom   = 12L,
    max_zoom   = 16L,
    base_zoom  = 16L,
    source_crs = "EPSG:4326",
    overwrite  = TRUE
  )

  cli::cli_alert_success(
    "county={county_fips}: {out_path} ({round(file.size(out_path)/1e6,1)} MB)"
  )
  out_path
}
