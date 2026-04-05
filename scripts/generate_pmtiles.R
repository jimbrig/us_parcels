# generate_pmtiles.R
#
# generates MLT PMTiles from GeoParquet using freestiler (Rust-powered, in-process).
# freestiler outputs MLT by default — MapLibre Tiles columnar format, natively decoded
# by MapLibre GL JS v5.12+. pmtiles.io also supports MLT.
#
# NOTE: freestile_file(engine="geoparquet") is NOT compiled in the Windows r-universe
# binary. always use freestile_query() with read_parquet() instead.
#
# THREE TILE ARTIFACTS (different zoom strategies per use case):
#
# 1. county PMTiles (z12-16, no drop_rate):
#    - full parcel coverage within one county
#    - no thinning — gaps are worse than density for exhaustive polygon data
#    - used for: embedded county maps, on-demand focused views
#    - file size: 5-100MB per county
#
# 2. state PMTiles (z10-16, drop_rate=2.5):
#    - z10-11: ~0.3-2% of features visible (indicates coverage, not for detail)
#    - z12-13: ~8-29% of features (neighbourhood browse)
#    - z14-16: 50-100% of features (full detail)
#    - used for: the main browsable parcel layer in a national map
#    - file size: 50-500MB per state
#
# 3. national overview (z0-10, TIGER boundaries — NOT parcel polygons):
#    - parcels are invisible below z10, so show county/state outlines instead
#    - used for: always-loaded base layer showing political coverage
#    - file size: ~5-20MB for all CONUS
#
# VIEWING: always use serve_tiles() + maplibre() with explicit zoom/center.
# view_tiles() opens at a zoom determined by the extent, which for counties and
# states is below min_zoom=12 where no tiles exist.
#
# county centers for navigation (from centroidx/centroidy columns in parquet):
#   Appling (001): lon=-82.32, lat=31.75
#   Fulton  (121): lon=-84.39, lat=33.77
#
# usage:
#   source("scripts/generate_pmtiles.R")
#   generate_county_pmtiles("13", "001")   # Appling County
#   generate_county_pmtiles("13", "121")   # Fulton County
#   generate_state_pmtiles("13")           # full Georgia (takes several minutes)
#   generate_all_county_pmtiles("13")      # all 159 GA counties in parallel

library(freestiler)

# ---- helpers ----------------------------------------------------------------

.state_parquet <- function(state) {
  sprintf("data/geoparquet/state=%s/parcels.parquet", state)
}

.county_parquet <- function(state, county) {
  sprintf("data/geoparquet/state=%s/county=%s/parcels.parquet", state, county)
}

.state_pmtiles <- function(state) {
  path <- sprintf("data/pmtiles/state=%s/parcels.pmtiles", state)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  path
}

.county_pmtiles <- function(state, county) {
  path <- sprintf("data/pmtiles/state=%s/county=%s/parcels.pmtiles", state, county)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  path
}

# ---- state-level PMTiles ----------------------------------------------------
# min_zoom=10: first visible at z10 with ~0.07% of features (proves data exists)
# max_zoom=16: full polygon resolution
# base_zoom=16: thinning reference — all features at z16, halved per zoom below
# drop_rate=2.5: z16=100% | z15=29% | z14=8% | z13=2% | z12=0.7% | z10=0.07%
#   rural counties stay dense at all zooms (low absolute count)
#   urban counties (Fulton: 372k) thin to ~260 features/tile at z10 — renderable
# streaming=always: required for 5M+ features
#
# exact DuckDB query: SELECT * FROM read_parquet('<state_parquet>')
#
generate_state_pmtiles <- function(state) {
  src  <- normalizePath(.state_parquet(state), winslash = "/")
  dest <- .state_pmtiles(state)

  if (!file.exists(src)) stop("state parquet not found: ", src)

  message("generating state=", state, " PMTiles -> ", dest)
  message("  source: ", src, " (", round(file.size(src) / 1e6), " MB)")
  message("  zoom: 10-16 | drop_rate: 2.5 | base_zoom: 16 | streaming")

  freestiler::freestile_query(
    query      = sprintf("SELECT * FROM read_parquet('%s')", src),
    output     = dest,
    layer_name = "parcels",
    tile_format = "mlt",
    min_zoom   = 10L,
    max_zoom   = 16L,
    base_zoom  = 16L,
    drop_rate  = 2.5,
    source_crs = "EPSG:4326",
    streaming  = "always",
    overwrite  = TRUE
  )

  message("  done: ", dest, " (", round(file.size(dest) / 1e6, 1), " MB)")
  invisible(dest)
}

# ---- county-level PMTiles ---------------------------------------------------
# uses freestile_query() with DuckDB — reads parquet via SQL, never loads into R.
# freestile_file(engine="geoparquet") requires FREESTILER_GEOPARQUET=true compile
# flag which is absent from the Windows r-universe binary. freestile_query() works
# on all platforms because it delegates to R's DuckDB package, not the Rust reader.
#
# exact DuckDB query:
#   SELECT * FROM read_parquet('<county_parquet>')
#
generate_county_pmtiles <- function(state, county) {
  src  <- normalizePath(.county_parquet(state, county), winslash = "/")
  dest <- .county_pmtiles(state, county)

  if (!file.exists(src)) stop("county parquet not found: ", src)

  sz <- round(file.size(src) / 1e6, 1)
  message("  county=", county, ": SELECT * FROM read_parquet('", src, "') (", sz, " MB)")

  freestiler::freestile_query(
    query      = sprintf("SELECT * FROM read_parquet('%s')", src),
    output     = dest,
    layer_name = "parcels",
    tile_format = "mlt",
    min_zoom   = 12L,
    max_zoom   = 16L,
    base_zoom  = 16L,
    source_crs = "EPSG:4326",
    overwrite  = TRUE
  )

  message("    written: ", round(file.size(dest) / 1e6, 1), " MB")
  invisible(dest)
}

# ---- all counties in parallel -----------------------------------------------
generate_all_county_pmtiles <- function(state, workers = 4L) {
  county_dirs <- list.dirs(
    sprintf("data/geoparquet/state=%s", state),
    recursive = FALSE, full.names = FALSE
  )
  counties <- sub("county=", "", county_dirs[grepl("^county=", county_dirs)])

  message("generating PMTiles for ", length(counties), " counties (", workers, " workers)")

  parallel::mclapply(counties, function(ct) {
    tryCatch(
      generate_county_pmtiles(state, ct),
      error = function(e) message("  FAILED county=", ct, ": ", conditionMessage(e))
    )
  }, mc.cores = workers)

  invisible(NULL)
}

# ---- CLI entrypoint ---------------------------------------------------------
if (!interactive()) {
  args <- commandArgs(trailingOnly = TRUE)

  state        <- NULL
  county       <- NULL
  all_counties <- FALSE

  i <- 1L
  while (i <= length(args)) {
    if (args[i] == "--state")        { i <- i + 1L; state  <- args[i] }
    else if (args[i] == "--county")  { i <- i + 1L; county <- args[i] }
    else if (args[i] == "--all-counties") { all_counties <- TRUE }
    i <- i + 1L
  }

  if (is.null(state)) stop("--state <fips> is required")

  if (all_counties) {
    generate_all_county_pmtiles(state)
  } else if (!is.null(county)) {
    generate_county_pmtiles(state, county)
  } else {
    generate_state_pmtiles(state)
  }
}
