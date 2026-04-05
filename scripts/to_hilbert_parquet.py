"""
hilbert-sort any vector source (FGB, Parquet, or any OGR-readable file) into
a GeoArrow ZSTD-compressed GeoParquet.

optimised row-group size (50k) and compression level (3) balance query
selectivity via metadata statistics against write throughput.

usage:
  uv run --with duckdb scripts/to_hilbert_parquet.py input.parquet output.parquet --state 13
  uv run --with duckdb scripts/to_hilbert_parquet.py input.fgb output.parquet --bbox -85.61,30.36,-80.84,35.0
"""
from __future__ import annotations

import argparse
from pathlib import Path

STATE_BOUNDS: dict[str, tuple[float, float, float, float]] = {
    "01": (-88.47, 30.22, -84.89, 35.01),
    "04": (-114.82, 31.33, -109.04, 37.00),
    "05": (-94.62, 33.00, -89.64, 36.50),
    "06": (-124.48, 32.53, -114.13, 42.01),
    "08": (-109.06, 36.99, -102.04, 41.00),
    "09": (-73.73, 40.95, -71.79, 42.05),
    "10": (-75.79, 38.45, -75.05, 39.84),
    "11": (-77.12, 38.79, -76.91, 38.99),
    "12": (-87.63, 24.52, -80.03, 31.00),
    "13": (-85.61, 30.36, -80.84, 35.00),
    "16": (-117.24, 41.99, -111.04, 49.00),
    "17": (-91.51, 36.97, -87.50, 42.51),
    "18": (-88.10, 37.77, -84.78, 41.76),
    "19": (-96.64, 40.38, -90.14, 43.50),
    "20": (-102.05, 36.99, -94.59, 40.00),
    "21": (-89.57, 36.50, -81.96, 39.15),
    "22": (-94.04, 28.93, -88.82, 33.02),
    "24": (-79.49, 37.91, -75.05, 39.72),
    "25": (-73.51, 41.24, -69.93, 42.89),
    "26": (-90.42, 41.70, -82.41, 48.19),
    "27": (-97.24, 43.50, -89.49, 49.38),
    "29": (-95.77, 35.99, -89.10, 40.61),
    "34": (-75.56, 38.93, -73.89, 41.36),
    "36": (-79.76, 40.50, -71.86, 45.02),
    "37": (-84.32, 33.84, -75.46, 36.59),
    "39": (-84.82, 38.40, -80.52, 42.33),
    "42": (-80.52, 39.72, -74.69, 42.27),
    "47": (-90.31, 34.98, -81.65, 36.68),
    "48": (-106.65, 25.84, -93.51, 36.50),
    "51": (-83.68, 36.54, -75.24, 39.47),
    "53": (-124.85, 45.54, -116.92, 49.00),
}


def _detect_geom_col(con: object, table_expr: str) -> str:
    schema = con.execute(f"DESCRIBE SELECT * FROM {table_expr}").fetchall()
    for row in schema:
        if "GEOMETRY" in str(row[1]).upper():
            return row[0]
    # geoarrow-encoded parquet stores geometry as STRUCT(x DOUBLE, y DOUBLE)[][][]
    # which has no GEOMETRY substring — fall back to well-known column names
    for row in schema:
        if row[0].lower() in ("geom", "geometry", "shape", "the_geom"):
            return row[0]
    raise ValueError(f"no geometry column found in {table_expr}")


def main() -> None:
    parser = argparse.ArgumentParser(description="hilbert-sort vector data to GeoParquet")
    parser.add_argument("input", nargs="?", help="input path (FGB or Parquet)")
    parser.add_argument("output", nargs="?", help="output Parquet path")
    parser.add_argument("-i", "--input-file", dest="input_file")
    parser.add_argument("-o", "--output-file", dest="output_file")
    parser.add_argument("--bbox", help="xmin,ymin,xmax,ymax for Hilbert extent")
    parser.add_argument("--state", help="state FIPS to use predefined bbox")
    args = parser.parse_args()

    input_path = Path(args.input_file or args.input or "").resolve()
    output_path = Path(args.output_file or args.output or "").resolve()
    if not input_path.name or not output_path.name:
        parser.error("input and output paths required")
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
    con.execute("INSTALL spatial; LOAD spatial;")

    suffix = input_path.suffix.lower()
    if suffix == ".parquet":
        table_expr = f"read_parquet('{input_path.as_posix()}')"
        geom_col = _detect_geom_col(con, table_expr)
        # geoarrow STRUCT columns cannot be cast to GEOMETRY in duckdb.
        # check if centroidx/centroidy columns exist (pre-computed in source data)
        # and use those for hilbert ordering instead.
        schema = con.execute(f"DESCRIBE SELECT * FROM {table_expr}").fetchall()
        col_type = next((str(r[1]) for r in schema if r[0] == geom_col), "")
        col_names = [r[0].lower() for r in schema]
        if "GEOMETRY" in col_type.upper():
            geom_expr = geom_col
        elif "centroidx" in col_names and "centroidy" in col_names:
            # ST_Hilbert(DOUBLE, DOUBLE, BOX_2D) overload — uses centroids
            geom_expr = "centroidx, centroidy"
        else:
            raise ValueError(
                f"GeoArrow parquet without centroidx/centroidy columns — "
                f"cannot compute Hilbert order. Re-export with GEOMETRY type "
                f"or add centroid columns."
            )
    elif suffix in (".fgb", ".geojson", ".gpkg"):
        table_expr = f"ST_Read('{input_path.as_posix()}')"
        geom_col = _detect_geom_col(con, table_expr)
        geom_expr = geom_col
    else:
        table_expr = f"ST_Read('{input_path.as_posix()}')"
        geom_col = _detect_geom_col(con, table_expr)
        geom_expr = geom_col

    bounds_sql = f"ST_Extent(ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}))"

    sql = f"""
    COPY (
        SELECT * FROM {table_expr}
        ORDER BY ST_Hilbert({geom_expr}, {bounds_sql})
    )
    TO '{output_path.as_posix()}'
    (FORMAT parquet, COMPRESSION zstd, COMPRESSION_LEVEL 3, ROW_GROUP_SIZE 50000);
    """
    print(f"hilbert-sorting {input_path.name} -> {output_path.name} ...")
    con.execute(sql)

    size_mb = output_path.stat().st_size / (1024 * 1024)
    print(f"wrote {output_path} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
