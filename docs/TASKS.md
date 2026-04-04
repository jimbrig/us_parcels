# Task Surface

This repo uses a layered task surface:

1. `pixi` is the canonical operator surface for repo workflows
2. `just` is a thin convenience wrapper around `pixi`
3. `package.json` is reserved for frontend and Playwright concerns

Use `pwsh -NoProfile` for direct PowerShell invocation when bypassing task runners.

## Install

```powershell
# pixi (canonical)
pixi install

# just (optional wrapper)
cargo install just
# or: scoop install just | winget install just

# PowerShell Core
winget install Microsoft.PowerShell
```

## Command Matrix

| Workflow | Preferred command | Wrapper |
|----------|-------------------|---------|
| Core stack up | `pixi run up` | `just up` |
| Core + ingest | `pixi run up-ingest` | `just up-ingest` |
| Core + raster | `pixi run up-raster` | `just up-raster` |
| Dev stack | `pixi run up-dev` | `just up-dev` |
| Stack down | `pixi run down` | `just down` |
| Stack status | `pixi run status` | `just status` |
| Showcase sample | `pixi run showcase` | `just showcase` |
| Validate artifacts | `pixi run validate -- --state 13` | `just validate 13` |
| Query MinIO | `pixi run query-minio` | `just query-minio` |
| Pipeline status | `pixi run pipeline -- -Action status` | `just pipeline-status` |
| Cloud state build | `pixi run pipeline -- -Action cloud-state -State 13 -Name georgia` | `just cloud-state 13 georgia` |
| Upload artifacts | `pixi run pipeline -- -Action upload-minio -State 13` | `just upload-minio 13` |
| Serve static frontend | `pixi run serve-map` | `just serve-map` |
| Map-only browser tests | `pixi run verify-map` | `just verify-map` |
| Full browser tests | `pixi run verify-browser` | `just verify` |
| Repo smoke checks | `pixi run check` | `just check` |

## Direct Script Usage

When calling scripts directly, always use:

```powershell
pwsh -NoProfile -File scripts/showcase.ps1
pwsh -NoProfile -File scripts/pipeline.ps1 -Action status
```

## Notes

- `package.json` should not be used as a second orchestration surface for Docker or pipeline workflows.
- `just` should stay close to `pixi` and avoid introducing independent logic.
- `scripts/` contains implementation entrypoints; `pixi` is the supported operator interface.

## Checks

`pixi run check` runs:

- DuckDB spatial smoke validation
- `pwsh` availability validation
- `ruff` for `services/ingest-api`
- `pytest` for `services/ingest-api`
