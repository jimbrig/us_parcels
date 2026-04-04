# Data Contract

## Purpose

This document defines the canonical dataset names, table semantics, storage paths, and validation expectations used across the repo.

## Canonical Source Dataset

| Item | Value |
|------|-------|
| raw file | `LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` |
| layer | `lr_parcel_us` |
| geometry CRS | WGS84 / EPSG:4326 |

## Canonical Relational Tables

| Table | Role | Status |
|-------|------|--------|
| `parcels.parcel_raw` | ingestion landing table | transient working representation |
| `parcels.parcel` | normalized serving table | canonical PostGIS table |
| `parcels.parcel_coverage` | coverage summary view | derived reporting view |

Rules:

- load raw extracts into `parcels.parcel_raw`
- normalize into `parcels.parcel` before claiming a PostGIS-backed dataset is production-ready
- expose `parcels.parcel_raw` only for debugging, staging, or pipeline inspection

## Canonical Artifact Layout

### local layout

```text
data/
  flatgeobuf/
    state=13/
      parcels.fgb
  geoparquet/
    state=13/
      parcels.parquet
  pmtiles/
    state=13/
      parcels.pmtiles
```

### object storage layout

```text
s3://geodata/parcels/state=13/parcels.fgb
s3://geodata/parcels/state=13/parcels.parquet
s3://geodata/parcels/state=13/parcels.pmtiles
```

Rules:

- use `state=XX` hive-style partition directories
- use `parcels` as the base object/file name for published artifacts
- do not introduce parallel legacy roots such as `geoparquet/` for newly published objects

## Canonical Field Semantics

### raw input examples

| Raw field | Normalized field |
|-----------|------------------|
| `parcelid` | `parcel_id` |
| `parcelid2` | `parcel_id_alt` |
| `parceladdr` | `parcel_address` |
| `ownername` | `owner_name` |
| `totalvalue` | `total_value` |
| `yearbuilt` | `year_built` |
| `usedesc` | `use_description` |
| `saleamt` | `sale_amount` |

Rules:

- raw naming may remain source-shaped in `parcel_raw`
- normalized/public-facing naming should use snake_case
- frontend sources must map raw vs normalized properties explicitly when both are supported

## Artifact Guarantees

### GeoParquet

- partitioned by `state`
- suitable for DuckDB reads via `read_parquet(..., hive_partitioning=true)`
- written with compression enabled
- intended for analytics and bounded spatial query workloads

### FlatGeoBuf

- single-state geometry streaming artifact
- intended for GDAL `/vsicurl/` and HTTP range requests

### PMTiles

- single-state or showcase tile artifact
- intended for direct MapLibre delivery via `pmtiles://`

## Validation Requirements

The minimum acceptable validation for a published state artifact set is:

1. artifact files exist at the canonical paths
2. GeoParquet can be read by DuckDB
3. GeoParquet passes a bounded spatial query
4. PMTiles is readable by the frontend or a tile fetch
5. FlatGeoBuf exists and is readable by GDAL tooling

## Compatibility Rules

- new workflows must publish to the canonical `parcels/state=XX/parcels.*` layout
- legacy paths may be read only for migration compatibility
- docs and scripts must not introduce new path conventions without an ADR
