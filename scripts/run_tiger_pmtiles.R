setwd("E:/GEODATA/us_parcels")
library(freestiler)

# use WKB-encoded parquet (freestiler's DuckDB fallback can't handle GeoArrow STRUCT)
src <- normalizePath("data/geoparquet/tiger/state=13/counties_wkb.parquet", winslash = "/")
dest <- "data/pmtiles/georgia/tiger_counties.pmtiles"
dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)

cat("TIGER counties:", src, "\n")

freestile_query(
  query      = sprintf("SELECT * FROM read_parquet('%s')", src),
  output     = dest,
  layer_name = "counties",
  tile_format = "mlt",
  min_zoom   = 0L,
  max_zoom   = 12L,
  source_crs = "EPSG:4326",
  overwrite  = TRUE
)

cat("done:", dest, "(", round(file.size(dest) / 1e6, 1), "MB )\n")
