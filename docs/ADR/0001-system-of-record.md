# ADR 0001: System Of Record

- status: accepted
- date: 2026-03-06

## Context

The repo previously mixed multiple competing descriptions of what the system treats as authoritative:

- the raw GPKG
- PostGIS
- cloud-native artifacts in object storage

That ambiguity created drift across docs, scripts, UI labels, and storage paths.

## Decision

The system uses a layered authority model.

### 1. raw source of record

- `LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` is the immutable raw source of record.
- It is the authoritative upstream input from which all subsets and artifacts are derived.

### 2. relational working authority

- PostGIS is the authoritative working surface for subsets that are actively loaded into the runtime stack.
- `parcels.parcel_raw` is the ingestion-stage relational landing table.
- `parcels.parcel` is the canonical normalized serving table for PostGIS-backed workflows.

### 3. published artifact authority

- The published artifact set in object storage is the authoritative delivery and analytics surface.
- The canonical published artifact set for each state partition is:
  - `parcels.parquet`
  - `parcels.fgb`
  - `parcels.pmtiles`

### 4. documentation authority

- ADRs decide architecture and policy.
- `docs/ARCHITECTURE.md` describes current system behavior.
- `README.md` is onboarding, not architecture arbitration.

## Consequences

### positive

- PostGIS remains first-class for development, search, joins, and local serving.
- Cloud-native artifacts remain first-class for scalable analytics and tile delivery.
- The repo can support both workflows without pretending they are the same thing.

### constraints

- scripts and UI labels must distinguish working tables from published artifacts
- `parcel_raw` must not be presented as the canonical serving model
- storage paths must converge on the `parcels/state=XX/parcels.*` convention
- docs under `docs/chats/` are reference material only

## Implementation Notes

- Use `pixi.toml` as the canonical operator surface.
- Keep `justfile` as a convenience wrapper.
- Keep `package.json` focused on frontend and browser-test concerns.
