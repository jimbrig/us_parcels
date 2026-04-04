# Roadmap

## Now

- keep the dual-path architecture coherent
- formalize `pixi` as the canonical task surface
- align docs, scripts, and UI labels to the canonical data contract
- keep the showcase flow small, verifiable, and iterable

## Next

- move frontend code toward a clearer monorepo `apps/` layout
- keep PostGIS focused on active working subsets and service-backed workflows
- keep published artifacts focused on object-storage delivery and analytics
- harden CI around smoke validation and frontend verification

## Later

- formalize db migrations if schema churn increases
- evaluate whether legacy style/config assets can be fully removed
- expand service-level tests and config validation

## Enrichment Themes

- Census ACS block groups
- FEMA flood zones
- Overture building footprints
- SSURGO soils
- NWI wetlands
- USGS 3DEP elevation

These should only be added once they fit the architecture and data contract rather than as isolated one-off additions.
