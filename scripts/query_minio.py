"""
query canonical published GeoParquet artifacts from MinIO with DuckDB.

usage: uv run --with duckdb scripts/query_minio.py
"""

import duckdb


PARQUET_GLOB = "s3://geodata/parcels/**/*.parquet"


def main():
    con = duckdb.connect()
    con.execute(
        """
        INSTALL httpfs;
        LOAD httpfs;
        LOAD spatial;
        SET s3_endpoint = 'localhost:9000';
        SET s3_access_key_id = 'minioadmin';
        SET s3_secret_access_key = 'minioadmin';
        SET s3_use_ssl = false;
        SET s3_url_style = 'path';
        """
    )

    print("=== canonical published parquet schema ===")
    cols = con.execute(
        f"""
        DESCRIBE SELECT * FROM read_parquet(
            '{PARQUET_GLOB}',
            hive_partitioning=true
        )
        """
    ).fetchall()
    for col in cols:
        print(f"  {col[0]:25s} {col[1]}")

    print("\n=== parcel count by published state partition ===")
    rows = con.execute(
        f"""
        SELECT
            state,
            count(*) AS parcels
        FROM read_parquet('{PARQUET_GLOB}', hive_partitioning=true)
        GROUP BY state
        ORDER BY state
        """
    ).fetchall()
    for row in rows:
        print(f"  state={row[0]}  parcels={row[1]:>8,}")

    print("\n=== georgia bbox query ===")
    row = con.execute(
        f"""
        SELECT count(*) AS parcels
        FROM read_parquet('{PARQUET_GLOB}', hive_partitioning=true)
        WHERE state = '13'
          AND ST_Intersects(geom, ST_MakeEnvelope(-84.5, 33.6, -84.2, 33.9))
        """
    ).fetchone()
    print(f"  state=13 bbox parcels={row[0]:,}")

    print("\n=== sample rows from published partition ===")
    rows = con.execute(
        f"""
        SELECT state, *
        FROM read_parquet('{PARQUET_GLOB}', hive_partitioning=true)
        WHERE state = '13'
        LIMIT 5
        """
    ).fetchall()
    for row in rows:
        print(f"  state={row[0]}")

    print("\ndone -- queries target the canonical published parquet layout only.")


if __name__ == "__main__":
    main()
