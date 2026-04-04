# Contributing

## Working Model

This repo is treated as a geospatial monorepo.

- `services/` holds backend service code
- `scripts/` holds data and ops entrypoints
- `config/` holds runtime config
- frontend interfaces currently live at the repo root and should evolve toward an `apps/`-style layout over time

## Command Conventions

- use `pixi` as the canonical repo task surface
- use `just` only as a thin wrapper around `pixi`
- use `package.json` only for frontend and Playwright tasks
- use `pwsh -NoProfile` for direct PowerShell execution

## Documentation Precedence

Follow docs in this order:

1. `docs/ADR/`
2. `docs/ARCHITECTURE.md`
3. `docs/DATA_CONTRACT.md` and `docs/RUNBOOK.md`
4. `README.md`
5. `docs/chats/` as non-normative references

## Definition Of Done

A change is not done until it includes all relevant items below:

- code/config changes are aligned with the architecture and data contract
- task surface changes are reflected in `pixi.toml` and any `just` wrappers
- user-facing workflow changes update the relevant docs
- validation evidence is provided
- new path or schema conventions do not conflict with the canonical contract

## ADR Guidance

Create or update an ADR when a change affects:

- system-of-record decisions
- runtime topology
- canonical storage layout
- repo-wide command conventions
- service responsibilities or boundaries

## Validation Expectations

Use the smallest realistic sample needed to prove behavior.

Preferred commands:

```powershell
pixi run check
pixi run showcase
pixi run verify-map
```

Run broader verification when touching service wiring or proxies.

## Things To Avoid

- adding a second orchestration surface beside `pixi`
- inventing new storage roots beside `parcels/state=XX/parcels.*`
- presenting `parcel_raw` as the canonical serving model
- treating exploratory notes as authoritative architecture
- planning or launching nationwide workloads as part of normal contributor iteration
