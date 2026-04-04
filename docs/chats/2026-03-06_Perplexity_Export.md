# LandRise Parcel GPKG: Conversion & Modernization Reference

***

## The Asset

- **100GB GeoPackage** of nationwide US parcels
- Geometries validated, exact, and precise
- Minimal fields sufficient for core use cases
- Currently queryable via GDAL for local extractions
- Serves as **source of truth** — never queried directly in production

***

## The Problem With Direct Use

| Issue | Impact |
|---|---|
| GPKG is SQLite-backed | Slow full-table scans via GDAL/DuckDB |
| No cloud-native access pattern | Can't do HTTP range requests |
| Single monolithic file | No partition pruning, full scan for any query |
| Not tile-friendly | Can't serve to MapLibre without a tile server |

***

## Three Derived Formats, Three Consumers

Every downstream artifact is derived from the GPKG via a single `ogr2ogr` FlatGeoBuf intermediate. The GPKG is **never directly queried in production**.

### Format 1: Hilbert-Sorted GeoParquet
**Consumer:** Parcel Agent (analytical bbox + attribute queries via DuckDB)

```sql
-- Stage 1: Get extent for free — no full scan
SELECT min_x, min_y, max_x, max_y FROM gpkg_contents WHERE table_name = 'parcels';

-- Stage 2: FGB → GeoParquet (hardcode extent, avoid double-scan)
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
- Hilbert curve ordering + embedded `bbox` column → DuckDB issues HTTP range requests for only matching row groups
- `COMPRESSION_LEVEL 3` (not 9): ~80% size benefit at 3× faster write speed
- `ROW_GROUP_SIZE 50000`: balance between scan granularity and overhead
- Query result: sub-second bbox queries on Azure Blob, no server

***

### Format 2: FlatGeoBuf
**Consumer:** Parcel Agent geometry streaming via GDAL `/vsicurl/`

```powershell
# GPKG → FGB: single sequential scan, fastest GDAL-native path
ogr2ogr -f FlatGeoBuf -where "state_fips = '13'" -progress GA_parcels.fgb parcels.gpkg
```

```r
# Agent tool: HTTP range streaming via GDAL virtual filesystem
sf::read_sf(
  "/vsicurl/https://landrise.blob.core.windows.net/geodata/parcels/state=GA/parcels.fgb",
  wkt_filter = "POLYGON((-84.5 33.6,-84.2 33.6,-84.2 33.9,-84.5 33.9,-84.5 33.6))"
)
```

**Key details:**
- R-tree spatial index in FGB header → HTTP client fetches only the relevant byte range
- No query engine needed — pure GDAL
- Fastest path from bbox → `sf` object in R
- FGB also serves as input to tippecanoe (avoids GeoJSON intermediary)

***

### Format 3: PMTiles
**Consumer:** MapLibre frontend — zero-server tile serving

```powershell
tippecanoe `
  --output=GA_parcels.pmtiles `
  --minimum-zoom=8 `
  --maximum-zoom=16 `
  --drop-densest-as-needed `
  --generate-ids `
  --layer=parcels `
  GA_parcels.fgb
```

```javascript
import { Protocol } from 'pmtiles'
maplibregl.addProtocol('pmtiles', new Protocol().tile)
map.addSource('parcels', {
  type: 'vector',
  url: 'pmtiles://https://landrise.blob.core.windows.net/tiles/GA_parcels.pmtiles'
})
```

**Key details:**
- Single-file archive on Azure Blob; tiles fetched via HTTP range per z/x/y
- No tile server required (Martin optional for caching/auth)
- tippecanoe accepts a **directory** of FGB files for national merged build
- High vertex-count states need `ST_SimplifyPreserveTopology` before tippecanoe

***

## The Conversion Pipeline

```
parcels.gpkg (100GB, source of truth, local disk)
    │
    ├─[ogrinfo]──────────────────► extent metadata (instant, from GPKG tables)
    │
    ├─[ogr2ogr, per-state -where]─► state_parcels.fgb
    │                                   │
    │              ┌────────────────────┼───────────────────┐
    │              ▼                    ▼                    ▼
    │   [DuckDB ST_Hilbert]    [stays as FGB]      [tippecanoe]
    │         │                        │                    │
    │   GeoParquet (blob)        FGB (blob)         PMTiles (blob)
    │   DuckDB range queries    GDAL /vsicurl/      MapLibre tiles
```

***

## Conversion Time Reality

The naive single-query approach (double GPKG scan) takes **14–24 hours** for 100GB. The correct pipeline:

| Stage | Tool | Time (100GB) |
|---|---|---|
| `ogrinfo` extent query | GDAL | Seconds |
| GPKG → FGB (per-state or full) | `ogr2ogr` | 2–4 hrs |
| FGB → Hilbert GeoParquet | DuckDB | 3–6 hrs |
| FGB → PMTiles | tippecanoe | 1–2 hrs |
| **Total** | | **~6–12 hrs** |

Run as a PowerShell background job with BurntToast on completion. The **per-state parallel approach** (52 concurrent `ogr2ogr` extracts) halves wall-clock time and aligns with the Hive partition structure.

***

## Storage Structure on Azure Blob

```
landrise-storage/
  geodata/
    catalog.json                          ← STAC root (future)
    parcels/
      state=GA/
        parcels.parquet                   ← Hilbert GeoParquet
        parcels.fgb                       ← FlatGeoBuf
        item.json                         ← STAC item (future)
      state=TX/
        parcels.parquet
        parcels.fgb
  tiles/
    parcels_national.pmtiles              ← Single merged national tile archive
```

DuckDB reads the Hive-partitioned directory natively:
```sql
SELECT * FROM 'az://landrise-storage/geodata/parcels/**/*.parquet'
WHERE state = 'GA' -- partition pruning: only opens GA file
```

***

## Practical Build Sequence

```
Day 1  Profile GPKG with DuckDB → extract state distribution + vertex stats
Day 2  Georgia extraction → generate 3 artifacts → validate each locally
Day 3  Push Georgia to Azure blob → validate HTTP range access in R + MapLibre
Day 4  Wire 3 Parcel Agent tools against live blob URLs
Day 5  Run national conversion loop (weekend job) → push all states
Later  Add STAC catalog → H3 aggregation layer → Overture buildings join
```

***

## The Three Agent Tools (Final Form)

```r
# Tool 1 — Find: analytical query (GeoParquet + DuckDB HTTP range)
parcel_bbox_query <- function(bbox, filters = NULL, limit = 500)

# Tool 2 — Geometry: precise spatial ops (FGB + GDAL /vsicurl/)
parcel_geometry_stream <- function(wkt_filter)

# Tool 3 — Enrich: single parcel detail (APN → landrise.reapi live call)
parcel_detail <- function(apn)
```

The agent calls Tool 1 to find candidates, Tool 2 for geometry-precise spatial joins, and Tool 3 **only on the final shortlist** — keeping ReAPI call counts minimal.