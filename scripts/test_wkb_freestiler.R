setwd("E:/GEODATA/us_parcels")
library(freestiler)

src <- normalizePath("data/geoparquet/test/fulton_wkb_sorted.parquet", winslash = "/")
dest <- "data/pmtiles/test/fulton_wkb_test.pmtiles"
dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)

cat("reading:", src, "\n")
freestile_query(
  query      = sprintf("SELECT * FROM read_parquet('%s') LIMIT 5000", src),
  output     = dest,
  layer_name = "parcels",
  tile_format = "mlt",
  min_zoom   = 12L,
  max_zoom   = 14L,
  base_zoom  = 14L,
  source_crs = "EPSG:4326",
  overwrite  = TRUE
)
cat("freestiler OK:", dest, "(", round(file.size(dest) / 1e6, 1), "MB)\n")

cat("\n--- DuckDB spatial test ---\n")
library(duckdb)
con <- DBI::dbConnect(duckdb::duckdb())
DBI::dbExecute(con, "INSTALL spatial; LOAD spatial;")

r <- DBI::dbGetQuery(con, sprintf("
  SELECT typeof(ANY_VALUE(geom)) AS geom_type, COUNT(*) AS n,
         MIN(ST_XMin(geom)) AS xmin, MAX(ST_XMax(geom)) AS xmax
  FROM read_parquet('%s')
", src))
cat("DuckDB OK:", r$geom_type, "| n:", r$n, "| xmin:", r$xmin, "| xmax:", r$xmax, "\n")

cat("\n--- sfarrow test ---\n")
library(sfarrow)
sf_data <- sfarrow::st_read_parquet(src)
cat("sfarrow OK: class:", paste(class(sf_data), collapse=", "),
    "| nrow:", nrow(sf_data), "| crs:", sf::st_crs(sf_data)$epsg, "\n")
