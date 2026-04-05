# _targets.R
#
# targets pipeline: GPKG -> GeoParquet -> (county partition) -> PMTiles
#
# usage:
#   targets::tar_make()                    # run everything sequentially
#   targets::tar_make_future(workers = 4)  # parallel with mirai/future
#   targets::tar_visnetwork()              # visualize the dag
#   targets::tar_outdated()                # which targets need re-running
#   targets::tar_read(state_parquet_13)    # inspect a specific target
#
# parallelism strategy:
#   - GPKG extraction:    deployment = "main"   (sequential - single SQLite reader)
#   - hilbert sort:       deployment = "worker" (parallel - pure DuckDB CPU work)
#   - county partition:   deployment = "worker" (parallel - per-state independent)
#   - PMTiles (state):    deployment = "worker" (parallel - freestiler in-process Rust)
#   - PMTiles (county):   deployment = "worker" (parallel - many small jobs)
#
# county partitioning:
#   included by default. reasons for CONUS:
#     1. selective blob storage downloads (county = 1-70 MB vs state = 0.3-3 GB)
#     2. incremental updates (re-tile only changed counties)
#     3. hive-partitioned DuckDB queries with county= predicate pushdown
#     4. county-level API serving
#   disable with: PIPELINE_PARTITION_COUNTIES = FALSE in .env
#
# blob storage:
#   after tar_make(), upload artifacts with:
#     pixi run upload-minio -- --state 13
#   or run the full upload step as a tar_target() (see "upload" targets below, commented out)

library(targets)
library(tarchetypes)
library(crew)

source("R/pipeline_functions.R")

# ---- configuration ----------------------------------------------------------

# states to process — edit this list to control scope.
# start with one or two states; add more once the pipeline is validated.
PIPELINE_STATES <- c(
  "13",  # Georgia    (done: parquet + county parquets exist)
  "37"   # North Carolina (extraction in progress)
  # "06",  # California
  # "12",  # Florida
  # "48",  # Texas
  # add remaining CONUS states here
)

# set FALSE to skip county partitioning (state-level parquet + PMTiles only)
PIPELINE_PARTITION_COUNTIES <- TRUE

# ---- crew controller --------------------------------------------------------
# mirai-backed local parallel workers.
# GPKG extraction targets use deployment = "main" to stay sequential.
# all other targets use deployment = "worker" and run in parallel here.
#
# workers: set to number of CPU cores minus 1. each worker is a fresh R process.
# tasks like hilbert sort and freestiler are CPU-bound; match to physical cores.
tar_option_set(
  packages   = c("freestiler", "cli", "withr", "processx"),
  controller = crew::crew_controller_local(workers = 4L),
  # store completed target values as files (avoids loading large data into memory)
  format     = "file"
)

# ---- helper: make per-state target list -------------------------------------

make_state_targets <- function(fips) {
  # sanitise fips for use in target names (targets names must be valid R identifiers)
  tag <- paste0("s", fips)

  list(
    # -- 1. extract raw (unsorted) parquet from GPKG --------------------------
    # deployment = "main": runs in the main R process, never in a worker.
    # this serialises all GPKG reads — SQLite handles one reader gracefully,
    # but concurrent ogr2ogr processes on the same 94GB file thrash the page cache.
    tar_target(
      name       = rlang::sym(paste0("raw_parquet_", tag)),
      command    = extract_state_parquet(!!fips),
      deployment = "main",
      format     = "file"
    ),

    # -- 2. hilbert-sort the raw parquet --------------------------------------
    # DuckDB CPU work: safe to parallelise across states.
    tar_target(
      name       = rlang::sym(paste0("state_parquet_", tag)),
      command    = hilbert_sort_parquet(!!rlang::sym(paste0("raw_parquet_", tag)), !!fips),
      deployment = "worker",
      format     = "file"
    ),

    # -- 3a. county partitioning (optional) -----------------------------------
    if (PIPELINE_PARTITION_COUNTIES) {
      tar_target(
        name       = rlang::sym(paste0("county_parquets_", tag)),
        command    = partition_by_county(!!rlang::sym(paste0("state_parquet_", tag)), !!fips),
        deployment = "worker",
        format     = "file"
      )
    },

    # -- 3b. state-level PMTiles ----------------------------------------------
    # freestile_query() with streaming=always: 1-2GB parquet never enters R.
    tar_target(
      name       = rlang::sym(paste0("state_pmtiles_", tag)),
      command    = tile_state_pmtiles(!!rlang::sym(paste0("state_parquet_", tag)), !!fips),
      deployment = "worker",
      format     = "file"
    ),

    # -- 3c. county-level PMTiles (optional, dynamic over county files) -------
    # dynamic branching: one sub-target per county file returned by step 3a.
    if (PIPELINE_PARTITION_COUNTIES) {
      tarchetypes::tar_map(
        values = list(
          county_parquet = rlang::sym(paste0("county_parquets_", tag))
        ),
        tar_target(
          name       = rlang::sym(paste0("county_pmtiles_", tag)),
          command    = tile_county_pmtiles(county_parquet),
          deployment = "worker",
          format     = "file"
        )
      )
    }
  ) |> purrr::compact()
}

# ---- pipeline ---------------------------------------------------------------

list(
  # expand per-state target groups
  purrr::map(PIPELINE_STATES, make_state_targets) |> unlist(recursive = FALSE)
)
