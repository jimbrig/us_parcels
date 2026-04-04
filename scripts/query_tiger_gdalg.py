"""validate TIGER edges GeoParquet output from GDALG pipeline."""
import duckdb

path = "data/geoparquet/tiger/state=13/county=121/edges.parquet"
con = duckdb.connect()
con.execute("INSTALL spatial; LOAD spatial;")

print(con.execute(f"""
    SELECT
        COUNT(*)                            AS total_edges,
        COUNT(DISTINCT MTFCC)               AS mtfcc_types,
        COUNT(*) FILTER (WHERE ROADFLG='Y') AS road_edges,
        MIN(STATEFP) || MIN(COUNTYFP)       AS fips
    FROM read_parquet('{path}')
""").fetchdf().to_string(index=False))
