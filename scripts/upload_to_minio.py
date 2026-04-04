"""
upload cloud pipeline artifacts to MinIO with Hive-style keys.
usage: uv run scripts/upload_to_minio.py [--state 13] [--base data]
"""
from __future__ import annotations

import argparse
from pathlib import Path

# optional: use minio package for uploads
try:
    from minio import Minio
    HAS_MINIO = True
except ImportError:
    HAS_MINIO = False


def main() -> int:
    parser = argparse.ArgumentParser(description="Upload cloud artifacts to MinIO")
    parser.add_argument("--state", help="state FIPS (e.g. 13); uploads state=N/ for that state")
    parser.add_argument("--base", default="data", help="base data directory")
    parser.add_argument("--bucket", default="geodata", help="MinIO bucket name")
    parser.add_argument("--prefix", default="parcels", help="object key prefix")
    parser.add_argument("--endpoint", default="localhost:9000", help="MinIO endpoint")
    parser.add_argument("--access-key", default="minioadmin", help="MinIO access key")
    parser.add_argument("--secret-key", default="minioadmin", help="MinIO secret key")
    parser.add_argument("--secure", action="store_true", help="use HTTPS")
    args = parser.parse_args()

    if not HAS_MINIO:
        print("install minio: uv add minio")
        return 1

    base = Path(args.base)
    client = Minio(
        args.endpoint,
        access_key=args.access_key,
        secret_key=args.secret_key,
        secure=args.secure,
    )

    if not client.bucket_exists(args.bucket):
        client.make_bucket(args.bucket)
        print(f"created bucket {args.bucket}")

    if args.state:
        state = args.state
        state_prefix = f"state={state}"
        artifacts = [
            (base / "geoparquet" / state_prefix / "parcels.parquet", f"{args.prefix}/{state_prefix}/parcels.parquet"),
            (base / "flatgeobuf" / state_prefix / "parcels.fgb", f"{args.prefix}/{state_prefix}/parcels.fgb"),
            (base / "pmtiles" / state_prefix / "parcels.pmtiles", f"{args.prefix}/{state_prefix}/parcels.pmtiles"),
        ]
    else:
        print("--state required")
        return 1

    for local_path, object_name in artifacts:
        if local_path.exists():
            client.fput_object(args.bucket, object_name, str(local_path))
            size_mb = local_path.stat().st_size / (1024 * 1024)
            print(f"  uploaded {object_name} ({size_mb:.2f} MB)")
        else:
            print(f"  skip (not found): {local_path}")

    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
