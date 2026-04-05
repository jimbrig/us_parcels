setwd("E:/GEODATA/us_parcels")
library(freestiler)

src <- normalizePath("data/geoparquet/state=13/parcels.parquet", winslash = "/")
dest <- "data/pmtiles/state=13/parcels.pmtiles"
dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)

cat("state=13 PMTiles\n")
cat("  source:", src, "(", round(file.size(src) / 1e6), "MB)\n")
cat("  zoom: 10-16 | drop_rate: 2.5 | base_zoom: 16 | streaming\n")

# streaming="always" requires Rust DuckDB backend (not compiled on Windows r-universe).
# without streaming, freestiler loads all features into R memory — 7M polygons will
# use ~4-8GB RAM but should complete. monitor memory pressure.
freestile_query(
  query      = sprintf("SELECT * FROM read_parquet('%s')", src),
  output     = dest,
  layer_name = "parcels",
  tile_format = "mlt",
  min_zoom   = 10L,
  max_zoom   = 16L,
  base_zoom  = 16L,
  drop_rate  = 2.5,
  source_crs = "EPSG:4326",
  overwrite  = TRUE
)

cat("done:", dest, "(", round(file.size(dest) / 1e6, 1), "MB)\n")
