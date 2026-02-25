#!/usr/bin/env python3
"""
DuckDB query helper for parcel GeoParquet files.

Usage:
    python scripts/query.py                    # run default summary query
    python scripts/query.py "SELECT * ..."     # run custom query
"""
import duckdb
import sys
from pathlib import Path

# resolve data directory relative to project root
project_root = Path(__file__).parent.parent
data_dir = project_root / "data" / "geoparquet"

default_query = f"""
SELECT 
    statefp || countyfp as fips,
    COUNT(*) as parcels,
    COUNT(parceladdr) as has_address,
    COUNT(totalvalue) as has_value,
    COUNT(ownername) as has_owner
FROM '{data_dir}/*.parquet'
GROUP BY fips
"""

query = sys.argv[1] if len(sys.argv) > 1 else default_query

result = duckdb.query(query)
print(result.fetchdf().to_string())
