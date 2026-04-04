# US Parcels Data Migration Plan

This document is a migration-oriented planning artifact. It is not the canonical architecture or system-of-record definition. See `docs/ARCHITECTURE.md` and `docs/ADR/0001-system-of-record.md` for the normative model.

## Overview

This document outlines the strategy for migrating 155M US parcel records from a local GeoPackage to:
1. **Azure Blob Storage** - Cloud-hosted Hive-partitioned GeoParquet
2. **DuckDB** - Serverless SQL analytics layer
3. **PostGIS** - Normalized relational database for production use

---

## Phase 1: Azure Blob Storage Setup

### 1.1 Prerequisites

```powershell
# install azure cli
winget install Microsoft.AzureCLI

# install azcopy (optimized for large file transfers)
winget install Microsoft.AzureCLI.AzCopy

# login to azure
az login

# create resource group and storage account
az group create --name rg-parcels --location eastus2
az storage account create `
  --name stparcelsdata `
  --resource-group rg-parcels `
  --location eastus2 `
  --sku Standard_LRS `
  --kind StorageV2 `
  --enable-hierarchical-namespace true  # enables ADLS Gen2 for better performance

# create container
az storage container create --name parcels --account-name stparcelsdata
```

### 1.2 Upload Strategy with AzCopy

AzCopy is optimized for large transfers (128GB in ~5 minutes reported):

```powershell
# get sas token for uploads
$end = (Get-Date).AddDays(7).ToString("yyyy-MM-ddTHH:mmZ")
$sas = az storage container generate-sas `
  --account-name stparcelsdata `
  --name parcels `
  --permissions rwdl `
  --expiry $end `
  --output tsv

# upload partitioned data
azcopy copy "data/geoparquet/*" "https://stparcelsdata.blob.core.windows.net/parcels/geoparquet/?$sas" --recursive

# for the source gpkg (if needed for backup)
azcopy copy "LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg" "https://stparcelsdata.blob.core.windows.net/parcels/source/?$sas"
```

### 1.3 Recommended Blob Structure

```
parcels/
├── geoparquet/
│   ├── statefp=01/
│   │   ├── countyfp=001/part_0000.parquet
│   │   ├── countyfp=003/part_0000.parquet
│   │   └── ...
│   ├── statefp=02/
│   │   └── ...
│   └── _metadata/
│       └── manifest.json
├── source/
│   └── LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg
└── exports/
    └── (ad-hoc exports)
```

---

## Phase 2: Hive-Partitioned GeoParquet Creation

### 2.1 Partitioning Strategy Options

| Strategy | Pros | Cons | Best For |
|----------|------|------|----------|
| **By State/County (Hive)** | Standard format, DuckDB native support, ~3,200 partitions | Many small directories | Production queries |
| **By State Only** | Simpler (51 files), easier management | Large files (~3GB avg) | Bulk analysis |
| **Spatial (S2/H3 cells)** | Best spatial query performance | Complex to create | Spatial-first apps |

**Recommendation**: State/County Hive partitioning for balance of query performance and manageability.

### 2.2 Using GDAL 3.12+ Vector Partition

```powershell
# create hive-partitioned structure (this will take several hours for full dataset)
pixi run gdal vector partition `
  --field statefp `
  --field countyfp `
  --format Parquet `
  --lco GEOMETRY_ENCODING=GEOARROW `
  --lco COMPRESSION=ZSTD `
  --lco ROW_GROUP_SIZE=100000 `
  --config OGR_SQLITE_CACHE 4000 `
  -i LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg `
  -o data/geoparquet_partitioned
```

### 2.3 Alternative: DuckDB Partitioned Write (after initial load)

```sql
-- if data is already in a single parquet or can be loaded
COPY (
    SELECT * FROM 'data/geoparquet/full_dataset.parquet'
)
TO 'data/geoparquet_partitioned'
(FORMAT PARQUET, PARTITION_BY (statefp, countyfp), COMPRESSION ZSTD);
```

### 2.4 Incremental Approach (Recommended for Testing)

Process one state at a time to avoid long-running jobs:

```powershell
# process states one at a time using spatial filter
$state_bounds = @{
    "13" = "-85.61 30.36 -80.84 35.00"  # Georgia
    "06" = "-124.48 32.53 -114.13 42.01" # California
    "48" = "-106.65 25.84 -93.51 36.50"  # Texas
    # ... add more
}

foreach ($state in $state_bounds.Keys) {
    $bbox = $state_bounds[$state]
    Write-Host "Processing state: $state"
    pixi run ogr2ogr `
      -f Parquet `
      -lco COMPRESSION=ZSTD `
      -lco GEOMETRY_ENCODING=GEOARROW `
      -spat $bbox.Split(" ") `
      "data/geoparquet_partitioned/statefp=$state/data.parquet" `
      LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg `
      lr_parcel_us
}
```

---

## Phase 3: DuckDB Cloud Querying

### 3.1 Azure Extension Setup

```sql
-- install and configure azure extension
INSTALL azure;
LOAD azure;

-- set connection string (from Azure portal > Storage Account > Access Keys)
SET azure_storage_connection_string = 'DefaultEndpointsProtocol=https;AccountName=stparcelsdata;AccountKey=YOUR_KEY;EndpointSuffix=core.windows.net';

-- or use SAS token
CREATE SECRET azure_secret (
    TYPE AZURE,
    CONNECTION_STRING 'your_connection_string'
);
```

### 3.2 Query Patterns

```sql
-- install spatial for geometry operations
INSTALL spatial;
LOAD spatial;

-- query with automatic hive partition pruning
SELECT parceladdr, ownername, totalvalue
FROM read_parquet('azure://parcels/geoparquet/**/*.parquet', hive_partitioning=true)
WHERE statefp = '13' AND countyfp = '121'  -- only reads Fulton County files
LIMIT 100;

-- aggregate by state
SELECT statefp, COUNT(*) as parcels, SUM(totalvalue) as total_value
FROM read_parquet('azure://parcels/geoparquet/**/*.parquet', hive_partitioning=true)
GROUP BY statefp
ORDER BY parcels DESC;

-- spatial query with bbox
SELECT *
FROM read_parquet('azure://parcels/geoparquet/**/*.parquet', hive_partitioning=true)
WHERE ST_Intersects(
    geom,
    ST_MakeEnvelope(-84.40, 33.74, -84.37, 33.77)
)
LIMIT 1000;
```

### 3.3 Create Persistent View

```sql
-- create a view for easier querying
CREATE VIEW parcels AS
SELECT *
FROM read_parquet('azure://parcels/geoparquet/**/*.parquet', hive_partitioning=true);

-- now query simply
SELECT * FROM parcels WHERE statefp = '06' LIMIT 10;
```

---

## Phase 4: PostGIS Normalized Schema

### 4.1 Schema Design

Based on the Land Record Parcel Standard with normalization:

```sql
-- enable extensions
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;  -- for text search

-- create schema
CREATE SCHEMA IF NOT EXISTS parcels;

-- lookup tables for normalization
CREATE TABLE parcels.states (
    statefp CHAR(2) PRIMARY KEY,
    state_name VARCHAR(50) NOT NULL,
    state_abbr CHAR(2) NOT NULL
);

CREATE TABLE parcels.counties (
    geoid CHAR(5) PRIMARY KEY,  -- statefp + countyfp
    statefp CHAR(2) REFERENCES parcels.states(statefp),
    countyfp CHAR(3) NOT NULL,
    county_name VARCHAR(100)
);

CREATE TABLE parcels.land_use_codes (
    use_code VARCHAR(20) PRIMARY KEY,
    use_description VARCHAR(255),
    use_category VARCHAR(50)  -- residential, commercial, industrial, etc.
);

-- main parcel table (normalized)
CREATE TABLE parcels.parcel (
    id BIGSERIAL PRIMARY KEY,
    parcel_id VARCHAR(100) NOT NULL,          -- renamed from parcelid
    parcel_id_alt VARCHAR(100),               -- renamed from parcelid2
    geoid CHAR(5) REFERENCES parcels.counties(geoid),
    
    -- tax info
    tax_account_num VARCHAR(50),              -- renamed from taxacctnum
    tax_year SMALLINT,                        -- renamed from taxyear
    
    -- land use
    use_code VARCHAR(20) REFERENCES parcels.land_use_codes(use_code),
    zoning_code VARCHAR(50),                  -- renamed from zoningcode
    zoning_desc VARCHAR(255),                 -- renamed from zoningdesc
    
    -- building info
    num_buildings SMALLINT,                   -- renamed from numbldgs
    num_units SMALLINT,                       -- renamed from numunits
    year_built SMALLINT,                      -- renamed from yearbuilt
    num_floors SMALLINT,                      -- renamed from numfloors
    building_sqft INTEGER,                    -- renamed from bldgsqft
    bedrooms SMALLINT,
    half_baths SMALLINT,                      -- renamed from halfbaths
    full_baths SMALLINT,                      -- renamed from fullbaths
    
    -- valuation
    improvement_value BIGINT,                 -- renamed from imprvalue
    land_value BIGINT,                        -- renamed from landvalue
    agricultural_value BIGINT,                -- renamed from agvalue
    total_value BIGINT,                       -- renamed from totalvalue
    assessed_acres NUMERIC(10,4),             -- renamed from assdacres
    
    -- sale info
    sale_amount BIGINT,                       -- renamed from saleamt
    sale_date DATE,                           -- renamed from saledate
    
    -- owner info
    owner_name VARCHAR(255),                  -- renamed from ownername
    owner_address VARCHAR(500),               -- renamed from owneraddr
    owner_city VARCHAR(100),                  -- renamed from ownercity
    owner_state VARCHAR(50),                  -- renamed from ownerstate
    owner_zip VARCHAR(20),                    -- renamed from ownerzip
    
    -- parcel address
    parcel_address VARCHAR(500),              -- renamed from parceladdr
    parcel_city VARCHAR(100),                 -- renamed from parcelcity
    parcel_state VARCHAR(50),                 -- renamed from parcelstate
    parcel_zip VARCHAR(20),                   -- renamed from parcelzip
    
    -- legal description
    legal_description TEXT,                   -- renamed from legaldesc
    
    -- PLSS fields
    plss_township VARCHAR(20),                -- renamed from township
    plss_section VARCHAR(20),                 -- renamed from section
    plss_quarter_section VARCHAR(20),         -- renamed from qtrsection
    plss_range VARCHAR(20),                   -- renamed from range
    plss_description VARCHAR(255),            -- renamed from plssdesc
    
    -- plat info
    plat_book VARCHAR(50),                    -- renamed from book
    plat_page VARCHAR(50),                    -- renamed from page
    plat_block VARCHAR(50),                   -- renamed from block
    plat_lot VARCHAR(50),                     -- renamed from lot
    
    -- metadata
    source_updated DATE,                      -- renamed from updated
    source_version VARCHAR(20),               -- renamed from lrversion
    
    -- geometry
    centroid GEOMETRY(POINT, 4326),           -- from centroidx/y
    surface_point GEOMETRY(POINT, 4326),      -- from surfpointx/y
    geom GEOMETRY(MULTIPOLYGON, 4326),
    
    -- constraints
    CONSTRAINT unique_parcel_per_county UNIQUE (geoid, parcel_id)
);

-- indexes for common queries
CREATE INDEX idx_parcel_geoid ON parcels.parcel(geoid);
CREATE INDEX idx_parcel_owner_name ON parcels.parcel USING gin(owner_name gin_trgm_ops);
CREATE INDEX idx_parcel_address ON parcels.parcel USING gin(parcel_address gin_trgm_ops);
CREATE INDEX idx_parcel_geom ON parcels.parcel USING gist(geom);
CREATE INDEX idx_parcel_centroid ON parcels.parcel USING gist(centroid);
CREATE INDEX idx_parcel_total_value ON parcels.parcel(total_value) WHERE total_value IS NOT NULL;
```

### 4.2 Field Mapping Reference

| Source Field | Target Field | Transform |
|--------------|--------------|-----------|
| `parcelid` | `parcel_id` | Direct |
| `parcelid2` | `parcel_id_alt` | Direct |
| `taxacctnum` | `tax_account_num` | Direct |
| `taxyear` | `tax_year` | Direct |
| `usecode` | `use_code` | FK to lookup |
| `usedesc` | (in lookup) | Normalize to lookup table |
| `numbldgs` | `num_buildings` | Direct |
| `numunits` | `num_units` | Direct |
| `yearbuilt` | `year_built` | Direct |
| `numfloors` | `num_floors` | Direct |
| `bldgsqft` | `building_sqft` | Direct |
| `halfbaths` | `half_baths` | Direct |
| `fullbaths` | `full_baths` | Direct |
| `imprvalue` | `improvement_value` | Direct |
| `landvalue` | `land_value` | Direct |
| `agvalue` | `agricultural_value` | Direct |
| `totalvalue` | `total_value` | Direct |
| `assdacres` | `assessed_acres` | Direct |
| `saleamt` | `sale_amount` | Direct |
| `saledate` | `sale_date` | Direct |
| `ownername` | `owner_name` | TRIM, UPPER |
| `owneraddr` | `owner_address` | Direct |
| `parceladdr` | `parcel_address` | Direct |
| `legaldesc` | `legal_description` | Direct |
| `centroidx/y` | `centroid` | ST_Point(x, y, 4326) |
| `surfpointx/y` | `surface_point` | ST_Point(x, y, 4326) |

### 4.3 ETL with ogr2ogr + SQL Transform

```powershell
# load a single county with field transformation
pixi run ogr2ogr `
  -f PostgreSQL `
  "PG:host=localhost dbname=parcels user=postgres password=secret" `
  data/geoparquet/atlanta_downtown.parquet `
  -nln parcels.parcel `
  -lco SCHEMA=parcels `
  -lco GEOMETRY_NAME=geom `
  -sql "SELECT
    parcelid AS parcel_id,
    parcelid2 AS parcel_id_alt,
    geoid,
    taxacctnum AS tax_account_num,
    taxyear AS tax_year,
    usecode AS use_code,
    zoningcode AS zoning_code,
    zoningdesc AS zoning_desc,
    numbldgs AS num_buildings,
    numunits AS num_units,
    yearbuilt AS year_built,
    numfloors AS num_floors,
    bldgsqft AS building_sqft,
    bedrooms,
    halfbaths AS half_baths,
    fullbaths AS full_baths,
    imprvalue AS improvement_value,
    landvalue AS land_value,
    agvalue AS agricultural_value,
    totalvalue AS total_value,
    assdacres AS assessed_acres,
    saleamt AS sale_amount,
    saledate AS sale_date,
    UPPER(TRIM(ownername)) AS owner_name,
    owneraddr AS owner_address,
    ownercity AS owner_city,
    ownerstate AS owner_state,
    ownerzip AS owner_zip,
    parceladdr AS parcel_address,
    parcelcity AS parcel_city,
    parcelstate AS parcel_state,
    parcelzip AS parcel_zip,
    legaldesc AS legal_description,
    township AS plss_township,
    section AS plss_section,
    qtrsection AS plss_quarter_section,
    range AS plss_range,
    plssdesc AS plss_description,
    book AS plat_book,
    page AS plat_page,
    block AS plat_block,
    lot AS plat_lot,
    updated AS source_updated,
    lrversion AS source_version,
    ST_Point(centroidx, centroidy, 4326) AS centroid,
    ST_Point(surfpointx, surfpointy, 4326) AS surface_point,
    geom
  FROM atlanta_downtown"
```

---

## Phase 5: Implementation Timeline

| Phase | Task | Duration | Dependencies |
|-------|------|----------|--------------|
| 1 | Azure setup & azcopy install | 1 hour | None |
| 2a | Test partition (1 county) | 30 min | Phase 1 |
| 2b | Full partition (all states) | 4-12 hours | Phase 2a success |
| 3 | Upload to Azure | 1-2 hours | Phase 2b |
| 4 | DuckDB Azure queries | 1 hour | Phase 3 |
| 5a | PostGIS schema setup | 2 hours | None |
| 5b | ETL single county test | 1 hour | Phase 5a |
| 5c | Full PostGIS load | 8-24 hours | Phase 5b success |

---

## Tools Summary

| Tool | Purpose | Install |
|------|---------|---------|
| `azcopy` | Fast Azure blob transfers | `winget install Microsoft.AzureCLI.AzCopy` |
| `az cli` | Azure management | `winget install Microsoft.AzureCLI` |
| `duckdb` | SQL analytics | `winget install DuckDB.cli` |
| `gdal/ogr2ogr` | Geospatial ETL | `pixi add gdal libgdal-arrow-parquet` |
| `psql` | PostgreSQL client | `winget install PostgreSQL.psql` |

---

## References

- [DuckDB Hive Partitioning](https://duckdb.org/docs/data/partitioning/hive_partitioning.html)
- [DuckDB Azure Extension](https://duckdb.org/docs/extensions/azure)
- [GDAL Vector Partition](https://gdal.org/programs/gdal_vector_partition.html)
- [GeoParquet Best Practices](https://github.com/opengeospatial/geoparquet/discussions/171)
- [Land Record Parcel Standard](https://github.com/land-record/parcel-standard)
- [AzCopy Upload Guide](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-blobs-upload)
