# Geospatial Formats & Serving Options Reference

A reference for the formats, tile specifications, and serving methods relevant to this project and modern geospatial infrastructure in general.

## Vector Data Formats

### GeoPackage (GPKG)

- **What:** SQLite-based container for vector features, rasters, and tiled data. OGC standard.
- **Strengths:** Self-contained single file, spatial index (R-tree), ACID transactions, widely supported by every GIS tool.
- **Weaknesses:** Poor cloud-native performance (no HTTP range request support), file locking issues with concurrent access, becomes unwieldy at 100+ GB.
- **Use here:** Source data format (155M parcels). Good for local storage and extraction but not for serving or analytics at scale.

### GeoParquet

- **What:** Apache Parquet with geospatial metadata (geometry column, CRS, bbox). Emerging OGC standard.
- **Strengths:** Columnar storage with per-column compression (ZSTD), predicate pushdown, compatible with the entire Arrow/Parquet ecosystem (DuckDB, pandas, Spark, R arrow). Cloud-native via HTTP range requests on row group metadata. Hive-partitioning support.
- **Weaknesses:** Not directly renderable in browsers. Requires a query engine (DuckDB, pandas) to read.
- **Encoding options:** WKB (default), GeoArrow (native Arrow geometry, faster for analytics).
- **Best practices:** Use ZSTD compression, GeoArrow encoding, spatial sorting (geohash or S2), row groups of 100-200K rows, bbox column for predicate pushdown.
- **Use here:** Primary analytics/storage format. Hive-partitioned by state FIPS on MinIO for DuckDB queries.

### FlatGeoBuf (FGB)

- **What:** Binary format with a built-in spatial index (packed Hilbert R-tree) in the file header. OGC Community Standard candidate.
- **Strengths:** HTTP range requests with spatial filtering -- a browser can request only features in a bounding box without downloading the whole file. No server needed beyond static file hosting (nginx, CDN).
- **Weaknesses:** Append-only (rewriting for updates is expensive), no columnar compression, larger than GeoParquet for the same data.
- **Use here:** Browser-consumable format for high-zoom interactive feature loading. Served via nginx at `http://localhost:8080/data/flatgeobuf/`.

### GeoJSON

- **What:** JSON-based vector format. The lingua franca of web mapping.
- **Strengths:** Human-readable, universally supported, easy to debug.
- **Weaknesses:** Verbose (10-100x larger than binary formats), no spatial index, no streaming support for large files.
- **Use here:** API responses from pg_featureserv. Not used for storage.

### Shapefile

- **What:** ESRI's legacy multi-file format (.shp, .shx, .dbf, .prj).
- **Strengths:** Universal legacy support.
- **Weaknesses:** 2 GB file size limit, 10-character field names, no null support, multi-file complexity. Effectively deprecated for new work.
- **Use here:** Not used. Mentioned only for completeness.

## Vector Tile Formats

### MVT (Mapbox Vector Tiles)

- **What:** Protocol buffer (protobuf) encoded vector data per tile, following the Mapbox Vector Tile Specification. Each tile contains geometry + attributes for a specific z/x/y extent.
- **Strengths:** De facto standard, supported by every major renderer (MapLibre, Mapbox GL, OpenLayers, Leaflet plugins, deck.gl). Compact binary encoding. Mature tooling (Tippecanoe, Planetiler, ogr2ogr, Martin, pg_tileserv).
- **Weaknesses:** Row-oriented protobuf encoding is less efficient than columnar approaches. No built-in compression beyond protobuf varint encoding (relies on HTTP gzip/brotli).
- **Use here:** Current tile encoding for Martin, pg_tileserv, and PMTiles output from ogr2ogr.

### MLT (MapLibre Tile)

- **What:** Next-generation vector tile format released January 2026 by the MapLibre project. Column-oriented layout with custom lightweight encodings, designed for modern GPU APIs.
- **Strengths:** Up to 6x better compression than MVT on large tiles, faster decoding via SIMD/vectorization, designed for GPU-friendly processing. Future support for 3D coordinates, linear referencing, m-values, and complex nested types (aligned with Overture Maps GeoParquet schema).
- **Status:** Production-ready in MapLibre GL JS and MapLibre Native (`encoding: "mlt"` on sources). Tile generation via Planetiler (upcoming) and the MLT encoding server (converts MVT to MLT on the fly).
- **Weaknesses:** Young ecosystem. ogr2ogr does not yet generate MLT. Fewer server-side tools support it compared to MVT.
- **Use here:** Future consideration. Once Planetiler's MLT support stabilizes, regenerating the nationwide PMTiles with MLT encoding could reduce file size from ~30-60 GB to ~5-15 GB.
- **Reference:** https://maplibre.org/news/2026-01-23-mlt-release/

## Tile Containers

### PMTiles

- **What:** Single-file archive for map tiles (vector or raster) with an internal offset index. Designed for cloud-native serving via HTTP range requests.
- **How it works:** The file header contains a directory that maps z/x/y tile coordinates to byte offsets. A client reads the header, then fetches individual tiles with HTTP Range requests. No tile server needed -- works on any static file host (CDN, S3, Azure Blob, Cloudflare R2, nginx).
- **Strengths:** Zero-infrastructure tile serving. Single file (no millions of z/x/y directories). Works with any CDN. The `pmtiles` JavaScript library reads them directly in the browser.
- **Weaknesses:** Tiles are pre-built at specific zoom levels -- no dynamic filtering or on-demand generation. Rebuilding requires regenerating the entire file.
- **Generation:** `ogr2ogr -f PMTiles` (GDAL), Tippecanoe, Planetiler, Martin (can also serve PMTiles).
- **Use here:** Primary static tile delivery format. Pre-built from GPKG or PostGIS, hosted on MinIO locally and CDN/blob storage in production.

### MBTiles

- **What:** SQLite database containing tiles as blobs, indexed by z/x/y.
- **Strengths:** Mature, well-supported.
- **Weaknesses:** Requires a tile server to read (SQLite is not cloud-native). Being superseded by PMTiles for web serving.
- **Use here:** Not used. PMTiles is preferred.

## Tile Servers

### Martin

- **What:** High-performance vector tile server written in Rust. Serves tiles from PostGIS tables/functions AND static PMTiles/MBTiles files.
- **Key feature:** Combines dynamic (PostGIS) and static (PMTiles) sources in a single server. Built-in web UI for tile inspection. Auto-discovers PostGIS tables.
- **Port:** 3000

### pg_tileserv

- **What:** Lightweight MVT tile server from CrunchyData. Reads directly from PostGIS.
- **Key feature:** Exposes PostGIS SQL functions as parameterized tile sources. You can write a SQL function that generates custom tiles (e.g., parcels colored by value) and pg_tileserv serves it as an XYZ tile endpoint.
- **Port:** 7800

### pg_featureserv

- **What:** OGC API Features server from CrunchyData. Serves GeoJSON features from PostGIS.
- **Key feature:** OGC-compliant API with filtering, spatial queries, pagination. Auto-discovers tables, views, and functions. Not a tile server -- returns raw GeoJSON features.
- **Port:** 9090

### TiTiler

- **What:** Dynamic raster tile server for Cloud Optimized GeoTIFFs (COGs).
- **Key feature:** On-the-fly reprojection, band math, color mapping, mosaic support. Built on GDAL/rasterio.
- **Port:** 8000 (profile: raster)

## Raster Formats (for enrichment layers)

### Cloud Optimized GeoTIFF (COG)

- **What:** Standard GeoTIFF with internal tiling and overviews, organized so HTTP range requests can fetch specific regions/zoom levels without downloading the whole file.
- **Strengths:** The raster equivalent of PMTiles -- cloud-native, works on any CDN/blob storage. Supported by GDAL, rasterio, TiTiler.
- **Use here:** Future elevation/terrain enrichment via USGS 3DEP COGs on AWS.

### GeoZarr

- **What:** Zarr format with geospatial metadata conventions. Chunked, compressed, multi-dimensional.
- **Strengths:** Excellent for multi-dimensional data (time series, multi-band). Cloud-native with HTTP range requests per chunk.
- **Use here:** Not currently relevant (no multi-dimensional data). Mentioned for completeness.

## Object Storage

### MinIO

- **What:** Self-hosted S3-compatible object storage.
- **Strengths:** Full S3 API compatibility (DuckDB httpfs, GDAL /vsis3/, R arrow all connect natively). Built-in web console. Single container, minimal footprint.
- **Use here:** Local object store for extracted GeoParquet, PMTiles, and FlatGeoBuf files. Dev-time substitute for Azure Blob / AWS S3.
- **Ports:** 9000 (S3 API), 9001 (web console)

## Enrichment Data Sources

### Census TIGER/Line + ACS

- **Coverage:** Nationwide
- **Key data:** Block group geometries + demographics (income, population, housing tenure, home values)
- **Format:** GeoPackage, Shapefile, or via `tidycensus` R package
- **Join type:** Point-in-polygon (parcel centroid within block group)
- **URL:** https://www2.census.gov/geo/tiger/

### FEMA National Flood Hazard Layer (NFHL)

- **Coverage:** Nationwide (per-state downloads)
- **Key data:** Flood zone designations (A, AE, V, X), base flood elevations
- **Format:** File GDB or ArcGIS Feature Server
- **Join type:** Intersection (% of parcel in floodplain)

### Overture Maps Buildings

- **Coverage:** Worldwide (2.6B+ footprints)
- **Key data:** Building footprints, height, class, floor count
- **Format:** GeoParquet on AWS S3 (free, no auth)
- **Join type:** Containment (buildings within parcel polygon)
- **Access:** DuckDB cloud query with hive partitioning + bbox filter

### SSURGO Soils

- **Coverage:** Nationwide
- **Key data:** Soil type, drainage class, hydric rating, flood frequency, slope, farmland classification
- **Format:** Nationwide GeoPackage (~15 GB)
- **Join type:** Intersection (parcel polygon intersects soil map unit)

### NWI Wetlands

- **Coverage:** Nationwide (per-state downloads)
- **Key data:** Wetland type and extent (Cowardin classification)
- **Format:** Shapefile or File GDB
- **Join type:** Intersection (% of parcel covered by wetlands)

### USGS 3DEP Elevation

- **Coverage:** CONUS at 1/3 arc-second (~10m), partial 1m
- **Key data:** Bare-earth elevation
- **Format:** Cloud Optimized GeoTIFF on AWS S3
- **Join type:** Raster point sampling at parcel centroid

### RealEstateAPI (landrise.reapi)

- **Coverage:** Nationwide (API, targeted lookups only)
- **Key data:** AVM valuation, tax history, sale history, mortgage, comps, demographics, owner contact info
- **Format:** JSON API (R client: `landrise.reapi`)
- **Join type:** Property ID or address match
- **Note:** Use sparingly. Not for bulk enrichment. Mock data available for demos.
