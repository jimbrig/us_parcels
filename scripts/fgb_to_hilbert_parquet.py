"""
convert FlatGeoBuf to Hilbert-sorted GeoParquet via DuckDB spatial extension.
enables sub-second bbox queries on object storage via HTTP range requests.

usage:
  uv run --with duckdb scripts/fgb_to_hilbert_parquet.py data/flatgeobuf/GA_parcels.fgb data/geoparquet/state=13/parcels.parquet
  uv run --with duckdb scripts/fgb_to_hilbert_parquet.py -i in.fgb -o out.parquet --bbox -85.61,30.36,-80.84,35.0
"""
from __future__ import annotations

import argparse
from pathlib import Path


# state FIPS -> bbox (xmin, ymin, xmax, ymax) for Hilbert extent
STATE_BOUNDS: dict[str, tuple[float, float, float, float]] = {
    "13": (-85.61, 30.36, -80.84, 35.00),  # Georgia
    "48": (-106.65, 25.84, -93.51, 36.50),  # Texas
    "06": (-124.48, 32.53, -114.13, 42.01),  # California
    "08": (-109.06, 36.99, -102.04, 41.00),  # Colorado
}


def main() -> None:
    parser = argparse.ArgumentParser(description="FGB to Hilbert-sorted GeoParquet")
    parser.add_argument("input", nargs="?", help="input FGB path")
    parser.add_argument("output", nargs="?", help="output parquet path")
    parser.add_argument("-i", "--input-file", dest="input_file", help="input FGB path")
    parser.add_argument("-o", "--output-file", dest="output_file", help="output parquet path")
    parser.add_argument("--bbox", help="xmin,ymin,xmax,ymax for Hilbert extent")
    parser.add_argument("--state", help="state FIPS (13=GA, 48=TX, etc.) to use predefined bbox")
    args = parser.parse_args()

    input_path = args.input_file or args.input
    output_path = args.output_file or args.output
    if not input_path or not output_path:
        parser.error("input and output paths required (positional or -i/-o)")

    input_path = Path(input_path).resolve()
    output_path = Path(output_path).resolve()
    if not input_path.exists():
        raise FileNotFoundError(f"input not found: {input_path}")

    if args.bbox:
        parts = [float(x.strip()) for x in args.bbox.split(",")]
        if len(parts) != 4:
            raise ValueError("bbox must be xmin,ymin,xmax,ymax")
        xmin, ymin, xmax, ymax = parts
    elif args.state and args.state in STATE_BOUNDS:
        xmin, ymin, xmax, ymax = STATE_BOUNDS[args.state]
    else:
        xmin, ymin, xmax, ymax = -180.0, -90.0, 180.0, 90.0

    output_path.parent.mkdir(parents=True, exist_ok=True)

    import duckdb

    con = duckdb.connect()
    con.execute("INSTALL spatial;")
    con.execute("LOAD spatial;")

    # detect geometry column from ST_Read schema
    schema = con.execute(f"DESCRIBE SELECT * FROM ST_Read('{input_path.as_posix()}')").fetchall()
    geom_col = None
    for row in schema:
        if "GEOMETRY" in str(row[1]).upper():
            geom_col = row[0]
            break
    if not geom_col:
        raise ValueError("no geometry column found in FGB")

    # extent for Hilbert ordering (ST_Extent of envelope per DuckDB spatial docs)
    bounds_sql = f"ST_Extent(ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}))"

    sql = f"""
    COPY (
        SELECT * FROM ST_Read('{input_path.as_posix()}')
        ORDER BY ST_Hilbert({geom_col}, {bounds_sql})
    )
    TO '{output_path.as_posix()}'
    (FORMAT parquet, COMPRESSION zstd, COMPRESSION_LEVEL 3, ROW_GROUP_SIZE 50000);
    """
    con.execute(sql)

    size_mb = output_path.stat().st_size / (1024 * 1024)
    print(f"wrote {output_path} ({size_mb:.2f} MB)")


if __name__ == "__main__":
    main()
