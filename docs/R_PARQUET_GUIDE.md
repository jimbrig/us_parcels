# Reading Georgia GeoParquet from R

The state parquet at `data/geoparquet/state=13/parcels.parquet` is:
- **1.39 GB**, **6,963,958 features**, Hilbert-sorted
- Geometry encoding: **GeoArrow** (native Arrow column type, not WKB binary)
- CRS: **EPSG:4326**
- Compression: **ZSTD**, row group size 50,000

The GeoArrow encoding is the important detail — some packages handle it transparently,
others need an explicit conversion step.

---

## Option 1: sfarrow (recommended — handles GeoArrow natively)

`sfarrow` has two distinct read functions with different signatures:

```r
library(sfarrow)
library(arrow)
library(dplyr)

# --- single file: st_read_parquet() ---
# reads the entire file as an sf object
county_001 <- sfarrow::st_read_parquet(
  "E:/GEODATA/us_parcels/data/geoparquet/state=13/county=001/parcels.parquet"
)

# --- hive-partitioned dataset: read_sf_dataset() ---
# signature: read_sf_dataset(dataset, find_geom = FALSE)
# 'dataset' must be a path to a DIRECTORY (arrow dataset root), not a single file
# filtering and column selection happen via arrow dplyr verbs before calling to_sf()

# open the county-partitioned directory as an Arrow dataset
ds <- arrow::open_dataset(
  "E:/GEODATA/us_parcels/data/geoparquet/state=13/",
  hive_style = TRUE
)

# filter to Fulton County, select columns, then convert to sf
fulton_sf <- ds |>
  dplyr::filter(countyfp == "121") |>
  dplyr::select(parcelid, parceladdr, parcelcity, totalvalue, usedesc, countyfp, geom) |>
  dplyr::collect() |>
  sfarrow::to_sf()

# tabular summary without loading geometry (fast)
county_summary <- ds |>
  dplyr::group_by(countyfp) |>
  dplyr::summarise(n = dplyr::n(), total_value = sum(totalvalue, na.rm = TRUE)) |>
  dplyr::collect() |>
  dplyr::arrange(dplyr::desc(n))
```

## Option 2: DuckDB in R (best for SQL queries and spatial ops)

DuckDB can read the GeoParquet natively including the GeoArrow geometry column.

```r
# install if needed: install.packages(c("duckdb", "DBI", "sf"))
library(duckdb)
library(DBI)
library(sf)

con <- dbConnect(duckdb())
dbExecute(con, "INSTALL spatial; LOAD spatial;")

# count by county — runs in seconds via DuckDB parallel scan
dbGetQuery(con, "
  SELECT countyfp, COUNT(*) AS n, SUM(totalvalue) AS total_assessed
  FROM read_parquet('data/geoparquet/state=13/parcels.parquet')
  GROUP BY countyfp
  ORDER BY n DESC
  LIMIT 10
")

# spatial query: bbox filter (fast — DuckDB uses parquet row group stats)
# exact query being run:
# SELECT ... FROM read_parquet(...) WHERE ST_Intersects(geom, ST_MakeEnvelope(...))
fulton_sf <- dbGetQuery(con, "
  SELECT
    parcelid, countyfp, totalvalue, usedesc,
    ST_AsText(geom) AS wkt
  FROM read_parquet('data/geoparquet/state=13/parcels.parquet')
  WHERE countyfp = '121'
    AND ST_Intersects(geom, ST_MakeEnvelope(-84.55, 33.60, -84.20, 33.95))
") |>
  sf::st_as_sf(wkt = "wkt", crs = 4326)

# larger value parcels in metro Atlanta
high_value <- dbGetQuery(con, "
  SELECT parcelid, parceladdr, parcelcity, totalvalue, yearbuilt, usedesc,
         ST_X(ST_Centroid(geom)) AS lon, ST_Y(ST_Centroid(geom)) AS lat
  FROM read_parquet('data/geoparquet/state=13/parcels.parquet')
  WHERE countyfp IN ('121', '089', '067', '135', '063')  -- metro ATL counties
    AND totalvalue > 1000000
  ORDER BY totalvalue DESC
  LIMIT 1000
")

dbDisconnect(con)
```

## Option 3: arrow package (no geometry — tabular analytics only)

Use this when you only need attribute data (no geometry rendering).

```r
library(arrow)
library(dplyr)

# lazy dataset — no data loaded until collect()
ds <- arrow::open_dataset("data/geoparquet/state=13/parcels.parquet")

# value distribution by county
ds |>
  dplyr::filter(countyfp == "121") |>
  dplyr::select(parcelid, totalvalue, usedesc, yearbuilt) |>
  dplyr::collect()  # pulls into R as tibble (geometry column is raw bytes — ignore it)

# county-level summary — runs via Arrow compute (fast, no geometry decode)
ds |>
  dplyr::group_by(countyfp) |>
  dplyr::summarise(
    n = dplyr::n(),
    median_value = median(totalvalue, na.rm = TRUE),
    median_acres = median(assdacres, na.rm = TRUE)
  ) |>
  dplyr::collect() |>
  dplyr::arrange(dplyr::desc(n))
```

## Option 4: sf via GDAL (works if your system GDAL has Parquet driver)

```r
library(sf)

# check if parquet driver is available
"Parquet" %in% sf::st_drivers()$name  # TRUE only with GDAL 3.5+ and arrow-parquet driver

# if available:
fulton <- sf::st_read(
  "data/geoparquet/state=13/parcels.parquet",
  query = "SELECT * FROM parcels WHERE countyfp = '121'"
)
```

---

## Working with county-level files (once partition_by_county.py runs)

After running `pixi run partition-county -- --state 13`, individual county files are at
`data/geoparquet/state=13/county=XXX/parcels.parquet`. These are smaller (5–30 MB each)
and faster to load for county-level work.

```r
# load a single county directly
library(sfarrow)
fulton <- sfarrow::read_sf_dataset("data/geoparquet/state=13/county=121/parcels.parquet")

# or with duckdb across all counties at once (hive partitioning)
library(duckdb)
con <- dbConnect(duckdb())
dbExecute(con, "INSTALL spatial; LOAD spatial;")
dbGetQuery(con, "
  SELECT county, COUNT(*) AS n
  FROM read_parquet('data/geoparquet/state=13/county=*/parcels.parquet',
                    hive_partitioning = true)
  GROUP BY county ORDER BY n DESC
")
```

---

## Field reference (key columns)

| Column | Type | Notes |
|---|---|---|
| `parcelid` | String | primary parcel identifier |
| `statefp` | String | state FIPS (e.g. `'13'` for GA) |
| `countyfp` | String | county FIPS (e.g. `'121'` for Fulton) |
| `totalvalue` | Int64 | total assessed value USD |
| `landvalue` | Int64 | land-only assessed value |
| `imprvalue` | Int64 | improvement (structure) value |
| `assdacres` | Double | assessed acres |
| `usecode` | String | land use code |
| `usedesc` | String | land use description |
| `yearbuilt` | Int32 | year structure built |
| `saleamt` | Int64 | last sale amount |
| `saledate` | DateTime | last sale date |
| `ownername` | String | owner name |
| `parceladdr` | String | parcel situs address |
| `geom` | Geometry | polygon, EPSG:4326, GeoArrow encoded |
| `centroidx` | Double | centroid longitude (pre-computed) |
| `centroidy` | Double | centroid latitude (pre-computed) |
