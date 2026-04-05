setwd("E:/GEODATA/us_parcels")
library(freestiler)

src <- normalizePath("data/geoparquet/state=13/parcels.parquet", winslash = "/")
dest <- "data/pmtiles/test/ga_large_parcels.pmtiles"
dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)

cat("large parcels from:", src, "\n")
cat("filter: assdacres > 1.0\n")

# no drop_rate: the size filter is the thinning mechanism.
# at z8, only parcels > 5 acres are large enough to render as polygons.
# at z10-12, 1+ acre parcels fill in the suburban/rural landscape.
freestile_query(
  query = sprintf("
    SELECT geom, parcelid, statefp, countyfp, usedesc,
           CAST(assdacres AS DOUBLE) AS acres,
           CAST(totalvalue AS BIGINT) AS totalvalue
    FROM read_parquet('%s')
    WHERE assdacres IS NOT NULL AND assdacres > 1.0
  ", src),
  output     = dest,
  layer_name = "parcels",
  tile_format = "mlt",
  min_zoom   = 8L,
  max_zoom   = 14L,
  base_zoom  = 14L,
  source_crs = "EPSG:4326",
  overwrite  = TRUE
)

cat("done:", dest, "(", round(file.size(dest) / 1e6, 1), "MB )\n")
