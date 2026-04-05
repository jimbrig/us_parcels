"""
partition a state-level hilbert GeoParquet into per-county files.

reads from the already-produced state parquet - no GPKG access needed.
output: state=XX/county=YYY/parcels.parquet (hive-compatible).

each county file is hilbert-sorted within its own bounding box.

exact duckdb queries run:
  1. SELECT DISTINCT countyfp ...             -- discover counties
  2. SELECT MIN/MAX of bbox per county        -- compute all bounds in one pass
  3. COPY (SELECT ... ORDER BY ST_Hilbert ...) -- write each county file

usage:
  uv run --with duckdb scripts/partition_by_county.py --state 13
  uv run --with duckdb scripts/partition_by_county.py --state 13 --parallelism 4
"""
from __future__ import annotations

import argparse
import concurrent.futures
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="partition state GeoParquet by county")
    parser.add_argument("--state", required=True, help="state FIPS (e.g. 13 for Georgia)")
    parser.add_argument("--parallelism", type=int, default=4, help="concurrent county writes (default 4)")
    parser.add_argument("--overwrite", action="store_true", help="overwrite existing county files")
    args = parser.parse_args()

    import duckdb

    state = args.state.zfill(2)
    base = Path("data/geoparquet")
    state_parquet = base / f"state={state}" / "parcels.parquet"
    if not state_parquet.exists():
        raise FileNotFoundError(f"state parquet not found: {state_parquet}")

    src = state_parquet.as_posix()

    # step 1: install/load spatial once in the main process
    con = duckdb.connect()
    print("installing duckdb spatial extension...")
    con.execute("INSTALL spatial; LOAD spatial;")

    # step 2: discover counties and compute all county bboxes in a SINGLE table scan
    print(f"computing county bounds from {state_parquet} ...")
    print(f"  query: SELECT countyfp, MIN/MAX of bbox FROM read_parquet('{src}') GROUP BY countyfp")
    # WKB-encoded parquets: ST_XMin/ST_XMax work directly on the geometry column
    rows = con.execute(f"""
        SELECT
            countyfp,
            MIN(ST_XMin(geom)) AS xmin,
            MIN(ST_YMin(geom)) AS ymin,
            MAX(ST_XMax(geom)) AS xmax,
            MAX(ST_YMax(geom)) AS ymax,
            COUNT(*) AS n
        FROM read_parquet('{src}')
        GROUP BY countyfp
        ORDER BY countyfp
    """).fetchall()
    con.close()

    counties = [
        {"fips": r[0], "bbox": (r[1], r[2], r[3], r[4]), "count": r[5]}
        for r in rows
    ]
    print(f"state={state}: {len(counties)} counties, {sum(c['count'] for c in counties):,} total features")

    # step 3: write each county file in parallel threads
    # each thread gets its own duckdb connection (duckdb connections are not shared across threads)
    def _write_county(county: dict) -> tuple[str, int, float]:
        import duckdb as _duckdb

        fips = county["fips"]
        xmin, ymin, xmax, ymax = county["bbox"]
        out_dir = base / f"state={state}" / f"county={fips}"
        out_path = out_dir / "parcels.parquet"

        if out_path.exists() and not args.overwrite:
            sz = out_path.stat().st_size / (1024 * 1024)
            print(f"  skip county={fips} (exists, {sz:.1f} MB)")
            return fips, 0, sz

        out_dir.mkdir(parents=True, exist_ok=True)
        bounds_sql = f"ST_Extent(ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}))"

        _con = _duckdb.connect()
        _con.execute("LOAD spatial;")  # already installed globally, just LOAD

        copy_sql = f"""
            COPY (
                SELECT * FROM read_parquet('{src}')
                WHERE countyfp = '{fips}'
                ORDER BY ST_Hilbert(geom, {bounds_sql})
            )
            TO '{out_path.as_posix()}'
            (FORMAT parquet, COMPRESSION zstd, COMPRESSION_LEVEL 9, ROW_GROUP_SIZE 10000)
        """
        print(f"  county={fips}: query: COPY (SELECT ... WHERE countyfp='{fips}' ORDER BY ST_Hilbert) TO ...")
        _con.execute(copy_sql)
        _con.close()

        sz = out_path.stat().st_size / (1024 * 1024)
        print(f"  county={fips}: done ({county['count']:,} features, {sz:.1f} MB)")
        return fips, county["count"], sz

    print(f"\nwriting {len(counties)} county files with parallelism={args.parallelism}...")
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallelism) as pool:
        results = list(pool.map(_write_county, counties))

    completed = [(f, n, s) for f, n, s in results if n > 0 or Path(base / f"state={state}" / f"county={f}" / "parcels.parquet").exists()]
    total_mb = sum(s for _, _, s in results)
    print(f"\ndone: {len(counties)} counties, {total_mb:.0f} MB total")
    print(f"hive path: {base}/state={state}/county=XXX/parcels.parquet")
    print("\nread all counties with duckdb:")
    print(f"  read_parquet('data/geoparquet/state={state}/county=*/parcels.parquet', hive_partitioning=true)")


if __name__ == "__main__":
    main()
