# Cloud-Native Parcel Pipeline Specification

Technical specification for the GPKG-to-cloud-artifacts conversion pipeline. Reference for [.cursor/plans/cloud-native_pipeline_phases_6f7172d8.plan.md](../.cursor/plans/cloud-native_pipeline_phases_6f7172d8.plan.md).

This document specifies the published artifact path only. For overall system authority and how this fits with PostGIS, see `docs/ARCHITECTURE.md` and `docs/ADR/0001-system-of-record.md`.

---

## Source Asset

- **100GB GeoPackage** of nationwide US parcels
- Geometries validated, exact, precise
- Minimal fields sufficient for core use cases
- **Never queried directly in production** — all downstream artifacts derived via extraction

---

## Why Not Query GPKG Directly

| Issue | Impact |
|-------|--------|
| SQLite-backed | Slow full-table scans via GDAL/DuckDB |
| No cloud-native access | Cannot do HTTP range requests |
| Single monolithic file | No partition pruning, full scan for any query |
| Not tile-friendly | Cannot serve to MapLibre without a tile server |

---

## Three Derived Formats, Three Consumers

Every downstream artifact is derived from the GPKG via a single `ogr2ogr` FlatGeoBuf intermediate.

### Format 1: Hilbert-Sorted GeoParquet

**Consumer:** DuckDB analytical queries (bbox + attribute filters)

```sql
LOAD spatial;
COPY (
  SELECT * FROM ST_Read('GA_parcels.fgb')
  ORDER BY ST_Hilbert(
    geometry,
    {'xmin':-85.6,'ymin':30.3,'xmax':-80.8,'ymax':35.0}::BOX_2D
  )
)
TO 'GA_parcels.parquet'
(FORMAT parquet, COMPRESSION zstd, COMPRESSION_LEVEL 3, ROW_GROUP_SIZE 50000);
```

**Key details:**
- Hilbert curve ordering + embedded bbox column enables DuckDB HTTP range requests for matching row groups only
- `COMPRESSION_LEVEL 3` (not 9): ~80% size benefit at 3x faster write speed
- `ROW_GROUP_SIZE 50000`: balance between scan granularity and overhead
- Result: sub-second bbox queries on object storage, no server

### Format 2: FlatGeoBuf

**Consumer:** GDAL geometry streaming via `/vsicurl/`

```powershell
ogr2ogr -f FlatGeoBuf -spat -85.61 30.36 -80.84 35.0 -progress GA_parcels.fgb parcels.gpkg lr_parcel_us
```

```r
sf::read_sf(
  "/vsicurl/https://storage.example.com/geodata/parcels/state=13/parcels.fgb",
  wkt_filter = "POLYGON((-84.5 33.6,-84.2 33.6,-84.2 33.9,-84.5 33.9,-84.5 33.6))"
)
```

**Key details:**
- R-tree spatial index in FGB header enables HTTP client to fetch only relevant byte range
- No query engine needed — pure GDAL
- FGB also serves as input to PMTiles generation (avoids GeoJSON intermediary)

### Format 3: PMTiles

**Consumer:** MapLibre frontend — zero-server tile serving

```powershell
tippecanoe --output=GA_parcels.pmtiles --minimum-zoom=8 --maximum-zoom=16 --drop-densest-as-needed --generate-ids --layer=parcels GA_parcels.fgb
```

**GDAL fallback** (when tippecanoe unavailable, e.g. Windows):

```powershell
ogr2ogr -f PMTiles -dsco MINZOOM=12 -dsco MAXZOOM=16 GA_parcels.pmtiles GA_parcels.fgb
```

**Key details:**
- Single-file archive on object storage; tiles fetched via HTTP range per z/x/y
- No tile server required
- tippecanoe accepts a directory of FGB files for national merged build
- High vertex-count states may need `ST_SimplifyPreserveTopology` before tippecanoe, or `-simplify` with GDAL

---

## Conversion Pipeline Flow

```
parcels.gpkg (source, local disk)
    │
    ├─[ogrinfo]──────────────────► extent metadata (instant, from gpkg_contents)
    │
    ├─[ogr2ogr, per-state -spat]──► state_parcels.fgb
    │                                   │
    │              ┌────────────────────┼───────────────────┐
    │              ▼                    ▼                    ▼
    │   [DuckDB ST_Hilbert]    [stays as FGB]      [tippecanoe or GDAL]
    │         │                        │                    │
    │   GeoParquet (blob)        FGB (blob)         PMTiles (blob)
    │   DuckDB range queries    GDAL /vsicurl/      MapLibre tiles
```

---

## Extraction Parameters

- **Filter method:** Use `-spat` (bbox) from state bounds. Do not assume `state_fips` or `statefp` column names in GPKG — bbox is reliable.
- **State bounds:** Georgia (FIPS 13): `-85.61 30.36 -80.84 35.00`
- **Layer name:** `lr_parcel_us` (from source GPKG)

---

## Storage Structure (Hive-Partitioned)

```
geodata/
  parcels/
    state=13/
      parcels.parquet
      parcels.fgb
      parcels.pmtiles
    state=48/
      parcels.parquet
      parcels.fgb
      parcels.pmtiles
```

DuckDB reads natively with partition pruning:

```sql
SELECT * FROM read_parquet('s3://geodata/parcels/**/*.parquet', hive_partitioning=true)
WHERE state = '13'
```

---

## Conversion Time Estimates (100GB Full Dataset)

| Stage | Tool | Time |
|-------|------|------|
| ogrinfo extent | GDAL | Seconds |
| GPKG → FGB (per-state or full) | ogr2ogr | 2–4 hrs |
| FGB → Hilbert GeoParquet | DuckDB | 3–6 hrs |
| FGB → PMTiles | tippecanoe/GDAL | 1–2 hrs |
| **Total** | | **~6–12 hrs** |

Per-state parallel approach (52 concurrent ogr2ogr extracts) halves wall-clock time and aligns with Hive partition structure.

---

## Tool Dependencies

| Tool | Purpose | Availability |
|------|---------|---------------|
| ogr2ogr (GDAL) | GPKG → FGB, FGB → PMTiles | pixi, Docker |
| DuckDB spatial | FGB → Hilbert GeoParquet | pixi (duckdb>=1.4.3) |
| tippecanoe | Higher-quality PMTiles, `--drop-densest-as-needed` | Docker (no conda-forge win-64) |
