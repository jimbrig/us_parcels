#!/bin/bash
# ingest.sh - load geospatial files into PostGIS via ogr2ogr
#
# designed for the GDAL Docker container (uses Docker network hostnames)
# but works anywhere ogr2ogr + libpq are available.
#
# usage:
#   ingest.sh <source_file> [source_layer] [target_table]
#
# examples:
#   ingest.sh data/geoparquet/georgia.parquet
#   ingest.sh data/geoparquet/georgia.parquet "" parcels.parcel_staging
#   ingest.sh LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg lr_parcel_us
#   ingest.sh data/flatgeobuf/atlanta_downtown.fgb

set -euo pipefail

PGHOST="${PGHOST:-postgis}"
PGPORT="${PGPORT:-5432}"
PGDB="${PGDATABASE:-parcels}"
PGUSER="${PGUSER:-parcels}"
PGPASS="${PGPASSWORD:-parcels}"

PG_CONN="PG:host=${PGHOST} port=${PGPORT} dbname=${PGDB} user=${PGUSER} password=${PGPASS}"

SOURCE="${1:?Usage: ingest.sh <source_file> [source_layer] [target_table]}"
SRC_LAYER="${2:-}"
TARGET="${3:-parcels.parcel_raw}"

echo "================================================================"
echo " PostGIS Ingest"
echo "================================================================"
echo " source:  ${SOURCE}"
echo " layer:   ${SRC_LAYER:-<auto>}"
echo " target:  ${TARGET}"
echo " host:    ${PGHOST}:${PGPORT}/${PGDB}"
echo "================================================================"

LAYER_ARGS=""
if [ -n "${SRC_LAYER}" ]; then
  LAYER_ARGS="${SRC_LAYER}"
fi

ogr2ogr \
  -f PostgreSQL "${PG_CONN}" \
  "${SOURCE}" ${LAYER_ARGS} \
  -nln "${TARGET}" \
  -lco GEOMETRY_NAME=geom \
  -lco SPATIAL_INDEX=NONE \
  -lco PRECISION=NO \
  -lco FID=ogc_fid \
  -append \
  -progress \
  --config PG_USE_COPY YES \
  --config OGR_TRUNCATE NO

echo ""
echo "==> loaded into ${TARGET}"
echo ""
echo "next steps:"
echo "  1. build spatial index:"
echo "     CREATE INDEX ON ${TARGET} USING gist(geom);"
echo "  2. verify row count:"
echo "     SELECT COUNT(*) FROM ${TARGET};"
echo "  3. check extent:"
echo "     SELECT ST_Extent(geom) FROM ${TARGET};"
