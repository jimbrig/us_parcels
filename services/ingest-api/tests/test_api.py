from __future__ import annotations

import importlib
import sys
from pathlib import Path

from fastapi.testclient import TestClient

SERVICE_DIR = Path(__file__).resolve().parents[1]


def load_main_module(monkeypatch, tmp_path: Path):
    missing_gpkg = tmp_path / "missing.gpkg"
    monkeypatch.setenv("GPKG_PATH", str(missing_gpkg))

    if str(SERVICE_DIR) not in sys.path:
        sys.path.insert(0, str(SERVICE_DIR))

    sys.modules.pop("main", None)
    module = importlib.import_module("main")
    return importlib.reload(module)


def test_extract_request_defaults(monkeypatch, tmp_path: Path):
    module = load_main_module(monkeypatch, tmp_path)
    req = module.ExtractRequest(name="demo", bbox=[0.0, 0.0, 1.0, 1.0])

    assert req.load_postgis is True
    assert req.table == "parcels.parcel_raw"
    assert req.formats == ["parquet"]


def test_health_reports_missing_gpkg(monkeypatch, tmp_path: Path):
    module = load_main_module(monkeypatch, tmp_path)
    client = TestClient(module.app)

    response = client.get("/health")

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert payload["gpkg_available"] is False
