# Runbook

## Core Bring-Up

```powershell
pixi run up
pixi run status
```

## Ingest Workflow

### start ingest-enabled stack

```powershell
pixi run up-ingest
```

### inspect pipeline status

```powershell
pixi run pipeline -- -Action status
```

### build a cloud-state artifact set

```powershell
pixi run pipeline -- -Action cloud-state -State 13 -Name georgia
pixi run pipeline -- -Action upload-minio -State 13
pixi run validate -- --state 13
```

## Showcase Workflow

Use the minimal showcase when you need a verifiable artifact without large workloads.

```powershell
pixi run showcase
pixi run serve-map
pixi run verify-map
```

## Browser Verification

### map-only

```powershell
pixi run verify-map
```

### full stack

```powershell
pixi run verify-browser
```

## Common Failures

### proxy endpoints fail

- confirm `pixi run up` is running
- confirm `config/nginx.conf` still maps `/tiles/`, `/features/`, `/tileserv/`, `/api/`, and `/s3/`

### martin layer mismatch

- confirm `config/martin.yaml` still points `parcels` at `parcels.parcel`
- restart Martin with `pixi run martin-config`

### MinIO queries fail

- confirm artifacts were uploaded to `s3://geodata/parcels/state=XX/parcels.*`
- confirm MinIO is reachable on `localhost:9000`
- rerun `pixi run query-minio`

### ingest-api tests fail

- rerun `pixi run lint-ingest-api`
- rerun `pixi run test-ingest-api`

## Operational Notes

- use PostGIS for active subset work
- use published artifacts for delivery and analytics validation
- avoid planning or running nationwide jobs as part of routine iteration
