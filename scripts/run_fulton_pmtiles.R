setwd("E:/GEODATA/us_parcels")
library(freestiler)

src <- normalizePath("data/geoparquet/state=13/county=121/parcels.parquet", winslash = "/")
dest <- "data/pmtiles/state=13/county=121/parcels.pmtiles"
dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)

cat("source:", src, "\n")
cat("dest:", dest, "\n")

freestile_query(
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

cat("done:", dest, "(", round(file.size(dest) / 1e6, 1), "MB )\n")
