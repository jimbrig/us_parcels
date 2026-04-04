# Cloud Pipeline Showcase

Minimal, iterable demonstration of the cloud-native conversion pipeline without requiring the full GPKG. Proves the flow: GeoJSON -> FGB -> Hilbert GeoParquet -> PMTiles.

## Prerequisites

- Docker Compose (stack running: `docker compose up -d`)
- pixi (for ogr2ogr)
- uv (for DuckDB)

## Run

```powershell
.\scripts\showcase.ps1
```

## What It Does

1. **GeoJSON -> FlatGeoBuf** via ogr2ogr (5 sample parcels in Atlanta)
2. **FGB -> Hilbert GeoParquet** via DuckDB spatial (`ST_Hilbert`, `ST_Read`)
3. **FGB -> PMTiles** via GDAL
4. **Validation** via `validate_cloud_artifacts.py` (DuckDB bbox query, file checks)

## Artifacts

| Path | Purpose |
|------|---------|
| `data/sample/showcase.geojson` | Input: 5 parcel polygons |
| `data/sample/showcase/parcels.fgb` | FlatGeoBuf intermediate |
| `data/sample/showcase/parcels.parquet` | Hilbert-sorted GeoParquet |
| `data/sample/showcase/parcels.pmtiles` | Vector tiles for MapLibre |

## View in Map

1. Ensure compose stack is running (`docker compose up -d`)
2. Open http://localhost:8080/map.html
3. Select "Showcase (cloud pipeline demo)" from the source dropdown
4. Map centers on Atlanta; click parcels for popup (address, owner, value, use)

## Verify Outcomes

- **DuckDB bbox query**: Validation prints parcel count in bbox and query time (expect sub-second)
- **PMTiles**: File exists; map renders parcels with value-based choropleth
- **FGB**: File exists; GDAL can read with `wkt_filter` for spatial queries
