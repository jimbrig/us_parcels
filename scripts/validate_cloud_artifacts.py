"""
validate cloud pipeline artifacts: Hilbert parquet bbox query, PMTiles file, optional FGB.
usage: uv run --with duckdb scripts/validate_cloud_artifacts.py [--state 13] [--parquet path] [--pmtiles path] [--fgb path]
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate cloud pipeline artifacts")
    parser.add_argument("--state", help="state FIPS (e.g. 13 for Georgia)")
    parser.add_argument("--parquet", help="path to Hilbert GeoParquet")
    parser.add_argument("--pmtiles", help="path to PMTiles file")
    parser.add_argument("--fgb", help="path to FlatGeoBuf (existence check only)")
    parser.add_argument("--bbox", default="-84.5,33.6,-84.2,33.9", help="bbox for query test xmin,ymin,xmax,ymax")
    args = parser.parse_args()

    base = Path("data")
    if args.state:
        state = args.state
        parquet_path = args.parquet or base / "geoparquet" / f"state={state}" / "parcels.parquet"
        pmtiles_path = args.pmtiles or base / "pmtiles" / f"state={state}" / "parcels.pmtiles"
        fgb_path = args.fgb or base / "flatgeobuf" / f"state={state}" / "parcels.fgb"
    else:
        parquet_path = Path(args.parquet) if args.parquet else None
        pmtiles_path = Path(args.pmtiles) if args.pmtiles else None
        fgb_path = Path(args.fgb) if args.fgb else None

    ok = True

    if parquet_path and parquet_path.exists():
        print("=== DuckDB bbox query (Hilbert parquet) ===")
        try:
            import duckdb
            con = duckdb.connect()
            con.execute("LOAD spatial;")
            schema = con.execute(f"DESCRIBE SELECT * FROM read_parquet('{parquet_path.as_posix()}')").fetchall()
            geom_col = next((r[0] for r in schema if "GEOMETRY" in str(r[1]).upper()), "geom")
            parts = [float(x.strip()) for x in args.bbox.split(",")]
            xmin, ymin, xmax, ymax = parts
            t0 = time.perf_counter()
            rows = con.execute(f"""
                SELECT count(*) as n
                FROM read_parquet('{parquet_path.as_posix()}')
                WHERE ST_Intersects({geom_col}, ST_MakeEnvelope({xmin},{ymin},{xmax},{ymax}))
            """).fetchone()
            elapsed = time.perf_counter() - t0
            n = rows[0] if rows else 0
            print(f"  bbox {args.bbox}: {n} parcels in {elapsed:.3f}s")
            if elapsed > 2.0:
                print("  warning: query took >2s (expected sub-second for Hilbert-sorted)")
        except Exception as e:
            print(f"  error: {e}")
            ok = False
    elif parquet_path:
        print(f"  parquet not found: {parquet_path}")
        ok = False

    if pmtiles_path and pmtiles_path.exists():
        print("\n=== PMTiles file ===")
        size_mb = pmtiles_path.stat().st_size / (1024 * 1024)
        print(f"  {pmtiles_path} ({size_mb:.2f} MB)")
        if size_mb < 0.01:
            print("  warning: file very small, may be empty")
    elif pmtiles_path:
        print(f"\n  pmtiles not found: {pmtiles_path}")
        ok = False

    if fgb_path and fgb_path.exists():
        print("\n=== FlatGeoBuf file ===")
        size_mb = fgb_path.stat().st_size / (1024 * 1024)
        print(f"  {fgb_path} ({size_mb:.2f} MB)")
    elif fgb_path:
        print(f"\n  fgb not found: {fgb_path}")

    print("\ndone" if ok else "\nvalidation had errors")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
