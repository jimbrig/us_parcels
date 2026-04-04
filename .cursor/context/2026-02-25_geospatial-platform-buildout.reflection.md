# Reflection: Geospatial Platform Buildout

**Date**: 2026-02-25
**Scope**: Full-session buildout of Docker-based geospatial data platform for 155M US parcels

## Direction Changes

Started as "set up docker compose with PostGIS and tile servers." Evolved significantly:

1. **PostGIS-centric -> dual-store architecture**: Early plan centered PostGIS as the only store. User pushed toward MinIO (S3-compatible) as a parallel storage layer for cloud-native formats, keeping PostGIS for serving and MinIO/GeoParquet for analytics via DuckDB. This dual-path (transactional + analytical) is the right architecture.

2. **Small samples -> nationwide extraction strategy**: Initial work loaded tiny city-scale extracts (~8K parcels). User clarified the real goal is systematically extracting from the full 155M-record GPKG into usable partitioned formats. The samples are proof-of-concept, not the deliverable.

3. **Showcase-first -> data-first**: User explicitly stated "the servicing is only as useful as the data it can serve." Shifted priority from adding more tile servers/UIs to understanding and improving the data itself (attribute coverage analysis, enrichment planning).

## Key Technical Findings

### Attribute coverage varies wildly by county assessor

This was the most important discovery. Queried 4 states:

| Field | CO (Denver) | TX (Dallas) | NY (Manhattan) | GA (Atlanta) |
|-------|-------------|-------------|----------------|--------------|
| totalvalue | 98% | 100% | 90% | 0% |
| yearbuilt | 80% | 0% | 90% | 0% |
| usedesc | 100% | 0% | 6% | 0% |
| saleamt | 93% | 0% | 0% | 0% |

**Implication**: The parcel geometry + ID + owner + address are the universal constants. Attribute enrichment must come from external sources (Census, FEMA, SSURGO, etc.), not from filling gaps in the source data.

### GPKG extraction performance through Docker

Extracting from the GPKG via Docker bind mount (`-v .:/workspace`) is noticeably slower than native pixi GDAL. The GPKG's spatial index helps but the Docker filesystem layer adds overhead, especially on Windows with the E: drive. For large state-scale extractions, native pixi GDAL (connecting to PostGIS via localhost:5432) would be faster if the PG driver is available.

However, pixi's GDAL activation was extremely slow (>90 seconds with no output), and the PG driver availability was never confirmed. The Docker GDAL path is more reliable even if slower.

### Martin source naming

Martin auto-discovers PostGIS tables but uses just the table name (not `schema.table`) as the source ID. `parcels.parcel_raw` becomes tile source `parcel_raw`, and the source-layer in MVT is also `parcel_raw`. This tripped up the dashboard map when switching from PMTiles to PostGIS source.

### Port conflicts matter

pg_featureserv defaulted to :9000 which conflicted with MinIO's standard S3 API port. Remapped pg_featureserv to :9090. This required updating every reference in index.html (service cards, health checks, PostGIS status loader).

## Corrections & Mistakes

- **Links in dashboard**: Generated `<a href target="_blank">` links that didn't work in the embedded Cursor browser. Fixed by switching to `<button onclick="window.open(...)">`. The underlying issue is that `target="_blank"` behavior varies by browser context.

- **HEREDOC in PowerShell**: Attempted `cat <<'EOF'` syntax for git commit messages. PowerShell doesn't support HEREDOC. Used multiple `-m` flags instead.

- **pixi GDAL PG driver**: Assumed pixi's conda GDAL would have the PostgreSQL driver. Never confirmed -- pixi activation was too slow to test. Fell back to Docker GDAL which definitely has it.

- **Martin command syntax**: Initially used `--profile tools` after `run` (`docker compose run --rm --profile tools gdal`). Docker Compose V2 requires profile before the subcommand: `docker compose --profile tools run --rm gdal`.

## Architecture Decisions (current state)

```
compose.yml services:
  postgis       :5432   PostgreSQL 17 + PostGIS 3.5 (tuned, 1GB shm)
  martin        :3000   vector tiles from PostGIS + PMTiles
  pg-tileserv   :7800   MVT from PostGIS tables/functions
  pg-featureserv:9090   OGC API Features (remapped from 9000)
  minio         :9000/1 S3-compatible object storage
  web           :8080   nginx (dashboard, map, ingest UI, styles)
  maputnik      :8888   visual MapLibre style editor
  ingest-api    :8001   FastAPI extraction backend (profile: ingest)
  titiler       :8000   raster COG tiles (profile: raster)
  gdal          --      on-demand GDAL container (profile: tools)
```

GitHub repo: https://github.com/jimbrig/us_parcels (public)

## Unresolved Items

- [ ] **Census enrichment not yet implemented** -- planned as highest-value spatial join (block group demographics). `tidycensus` R package or direct TIGER GeoPackage download.
- [ ] **MinIO not yet populated** -- service runs but no buckets/data uploaded. Need to create `geodata` bucket and upload extracted parquets.
- [ ] **Ingest API not tested end-to-end** -- Dockerfile written, compose service defined, but never built/started (`--profile ingest`). The FastAPI service needs the GPKG accessible inside the container.
- [ ] **Nationwide PMTiles generation** -- identified as the single most impactful deliverable for goal B (self-hosted vector tile layer). Estimated 4-12 hours local, 30-60 GB output. Could also be done on a cloud VM.
- [ ] **MLT (MapLibre Tile) format** -- user corrected that MLT is a distinct new format (Jan 2026), not just MVT rebranded. Column-oriented, 6x better compression. Future consideration once Planetiler supports generation.
- [ ] **DuckDB -> MinIO query path** -- documented but not demonstrated. Need to show `SET s3_endpoint = 'localhost:9000'` + `read_parquet('s3://geodata/...')` working end-to-end.
- [ ] **Shiny app for management UI** -- user expressed strong interest in bslib + mapgl + reactable + shinychat/ellmer. Deferred to future session after data pipeline is stable.
- [ ] **Custom Docker images / GHCR** -- discussed but deferred. Not valuable until configs are customized beyond upstream defaults. Dashboard (nginx + static files) is the quick-win candidate.

## Learned Preferences

- User is deeply knowledgeable about geospatial tooling -- don't oversimplify or conflate formats (MVT vs MLT distinction matters)
- Prefers exploring options before committing -- plan mode was appropriate for architecture decisions
- Values real data analysis over theoretical architecture ("data side first, servicing only as useful as what it can serve")
- Interested in both CLI power-user path AND visual interfaces (HTML prototype -> Shiny evolution)
- RealEstateAPI access available but use sparingly -- mock data at `X:/LANDRISE/landrise.reapi/dev/responses/` for demos
- GitHub workflow: `gh cli` preferred over manual setup. Comfortable with public repos.

## Context Updates

The following items should be considered for promotion to permanent context:

### .cursor/rules (new rule candidate)
- [ ] `geospatial-formats.mdc` -- reference that MVT and MLT are distinct tile encodings (not interchangeable names). PMTiles is a container, not an encoding. Link to `docs/FORMATS.md`.
- [ ] `docker-compose-profiles.mdc` -- profile flag goes before the subcommand: `docker compose --profile X run`, not `docker compose run --profile X`.

### AGENTS.md (if created)
- [ ] Note that Martin source IDs strip the schema prefix (table `parcels.parcel_raw` becomes source `parcel_raw`)
- [ ] Note that pixi GDAL on Windows has very slow activation time and unconfirmed PG driver support -- prefer Docker GDAL for PostGIS operations

---

**Apply these updates?** [User decision required]
