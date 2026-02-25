"""
query GeoParquet files stored in MinIO via DuckDB's S3/httpfs extension.
demonstrates the analytical query path without touching PostGIS.

usage: uv run --with duckdb scripts/query_minio.py
"""
import duckdb


def main():
    con = duckdb.connect()
    con.execute("""
        INSTALL httpfs;
        LOAD httpfs;
        SET s3_endpoint = 'localhost:9000';
        SET s3_access_key_id = 'minioadmin';
        SET s3_secret_access_key = 'minioadmin';
        SET s3_use_ssl = false;
        SET s3_url_style = 'path';
    """)

    print("=== schema: parcels_normalized.parquet (from MinIO S3) ===")
    cols = con.execute("""
        DESCRIBE SELECT * FROM read_parquet(
            's3://geodata/geoparquet/parcels_normalized.parquet'
        )
    """).fetchall()
    for col in cols:
        print(f"  {col[0]:25s} {col[1]}")

    print("\n=== parcel count by state ===")
    rows = con.execute("""
        SELECT
            substring(geoid, 1, 2) as statefp,
            count(*) as parcels,
            count(total_value) as has_value,
            round(avg(total_value), 0) as avg_value
        FROM read_parquet('s3://geodata/geoparquet/parcels_normalized.parquet')
        GROUP BY substring(geoid, 1, 2)
        ORDER BY parcels DESC
    """).fetchall()
    for row in rows:
        val = f"${row[3]:,.0f}" if row[3] else "N/A"
        print(f"  state={row[0]}  parcels={row[1]:>6,}  has_value={row[2]:>6,}  avg_value={val}")

    print("\n=== all parquets in geodata bucket ===")
    rows = con.execute("""
        SELECT
            regexp_extract(filename, '[^/]+$') as file_name,
            count(*) as rows
        FROM read_parquet(
            's3://geodata/geoparquet/*.parquet',
            filename=true,
            union_by_name=true
        )
        GROUP BY filename
        ORDER BY rows DESC
    """).fetchall()
    for row in rows:
        print(f"  {row[0]:40s} {row[1]:>7,} rows")

    print("\n=== top 5 highest-value parcels (from S3, no PostGIS) ===")
    rows = con.execute("""
        SELECT parcel_id, parcel_address, parcel_city, total_value
        FROM read_parquet('s3://geodata/geoparquet/parcels_normalized.parquet')
        WHERE total_value IS NOT NULL
        ORDER BY total_value DESC
        LIMIT 5
    """).fetchall()
    for row in rows:
        print(f"  {row[0]:20s} {(row[1] or ''):40s} {(row[2] or ''):15s} ${row[3]:>15,}")

    print("\ndone -- all queries hit MinIO S3, zero PostGIS involvement.")


if __name__ == "__main__":
    main()
