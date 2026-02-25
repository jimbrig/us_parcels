"""
ingestion API -- extracts parcels from GPKG by bounding box,
loads into PostGIS, and optionally exports to derivative formats.
"""
import os
import json
import subprocess
import tempfile
import threading
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

app = FastAPI(title="Parcels Ingestion API", version="0.1.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

GPKG_PATH = os.environ.get("GPKG_PATH", "/workspace/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg")
GPKG_LAYER = os.environ.get("GPKG_LAYER", "lr_parcel_us")
PG_CONN = (
    f"PG:host={os.environ.get('PGHOST', 'postgis')} "
    f"port={os.environ.get('PGPORT', '5432')} "
    f"dbname={os.environ.get('PGDATABASE', 'parcels')} "
    f"user={os.environ.get('PGUSER', 'parcels')} "
    f"password={os.environ.get('PGPASSWORD', 'parcels')}"
)

jobs: dict[str, dict] = {}


class ExtractRequest(BaseModel):
    name: str = Field(..., description="name for this extract (used in filenames)")
    bbox: list[float] = Field(..., min_length=4, max_length=4, description="[xmin, ymin, xmax, ymax]")
    load_postgis: bool = Field(True, description="load into PostGIS after extraction")
    table: str = Field("parcels.parcel_raw", description="target PostGIS table")
    formats: list[str] = Field(["parquet"], description="output formats: parquet, pmtiles, fgb")
    simplify: float | None = Field(None, description="simplification tolerance (degrees), e.g. 0.0001")


class JobStatus(BaseModel):
    id: str
    status: str
    name: str
    log: list[str]
    outputs: list[str]


def run_extraction(job_id: str, req: ExtractRequest):
    """run the extraction pipeline in a background thread."""
    job = jobs[job_id]
    job["status"] = "running"
    outputs = []

    try:
        bbox = req.bbox
        spat = [str(bbox[0]), str(bbox[1]), str(bbox[2]), str(bbox[3])]

        for fmt in req.formats:
            driver = {"parquet": "Parquet", "pmtiles": "PMTiles", "fgb": "FlatGeoBuf"}[fmt]
            ext = {"parquet": "parquet", "pmtiles": "pmtiles", "fgb": "fgb"}[fmt]
            subdir = {"parquet": "geoparquet", "pmtiles": "pmtiles", "fgb": "flatgeobuf"}[fmt]
            out_path = f"/workspace/data/{subdir}/{req.name}.{ext}"

            Path(out_path).parent.mkdir(parents=True, exist_ok=True)

            cmd = ["ogr2ogr", "-f", driver]

            if fmt == "parquet":
                cmd += ["-lco", "COMPRESSION=ZSTD", "-lco", "GEOMETRY_ENCODING=GEOARROW"]
            if fmt == "pmtiles":
                cmd += ["-dsco", "MINZOOM=12", "-dsco", "MAXZOOM=16", "-dsco", f"NAME={req.name}"]
            if req.simplify:
                cmd += ["-simplify", str(req.simplify)]

            cmd += ["-spat"] + spat + [out_path, GPKG_PATH, GPKG_LAYER]

            job["log"].append(f"extracting {fmt}: {' '.join(cmd[-4:])}")
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)

            if result.returncode != 0:
                job["log"].append(f"error: {result.stderr[:500]}")
                job["status"] = "failed"
                return

            job["log"].append(f"  -> {out_path}")
            outputs.append(out_path)

        if req.load_postgis and "parquet" in req.formats:
            parquet_path = f"/workspace/data/geoparquet/{req.name}.parquet"
            job["log"].append(f"loading into PostGIS ({req.table})")

            cmd = [
                "ogr2ogr", "-f", "PostgreSQL", PG_CONN, parquet_path,
                "-nln", req.table,
                "-lco", "GEOMETRY_NAME=geom",
                "-lco", "SPATIAL_INDEX=NONE",
                "-lco", "PRECISION=NO",
                "-append",
                "--config", "PG_USE_COPY", "YES"
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)

            if result.returncode != 0:
                job["log"].append(f"PostGIS load error: {result.stderr[:500]}")
                job["status"] = "failed"
                return

            job["log"].append("loaded into PostGIS")
            outputs.append(f"postgis:{req.table}")

        job["outputs"] = outputs
        job["status"] = "completed"
        job["log"].append("done")

    except Exception as e:
        job["log"].append(f"exception: {str(e)}")
        job["status"] = "failed"


@app.get("/health")
def health():
    gpkg_exists = Path(GPKG_PATH).exists()
    return {"status": "ok", "gpkg_available": gpkg_exists, "gpkg_path": GPKG_PATH}


@app.post("/extract", response_model=JobStatus)
def extract(req: ExtractRequest):
    import uuid
    job_id = str(uuid.uuid4())[:8]
    jobs[job_id] = {
        "id": job_id,
        "status": "queued",
        "name": req.name,
        "log": [f"queued: {req.name} bbox={req.bbox}"],
        "outputs": []
    }
    thread = threading.Thread(target=run_extraction, args=(job_id, req), daemon=True)
    thread.start()
    return jobs[job_id]


@app.get("/jobs")
def list_jobs():
    return list(jobs.values())


@app.get("/jobs/{job_id}", response_model=JobStatus)
def get_job(job_id: str):
    if job_id not in jobs:
        raise HTTPException(404, f"job {job_id} not found")
    return jobs[job_id]


@app.get("/data")
def list_data():
    """list extracted data files on disk."""
    base = Path("/workspace/data")
    files = []
    for subdir in ["geoparquet", "pmtiles", "flatgeobuf"]:
        d = base / subdir
        if d.exists():
            for f in d.iterdir():
                if f.is_file() and f.name != ".gitkeep":
                    files.append({
                        "name": f.name,
                        "format": subdir,
                        "size_mb": round(f.stat().st_size / 1024 / 1024, 2),
                        "path": str(f.relative_to(base))
                    })
    return files
