# justfile - convenience wrappers around pixi
# install: cargo install just | scoop install just | winget install just
# usage: just [recipe] | just --list

set windows-shell := ["pwsh", "-NoProfile", "-Command"]

up:
    pixi run up

up-ingest:
    pixi run up-ingest

up-raster:
    pixi run up-raster

up-dev:
    pixi run up-dev

down:
    pixi run down

logs:
    pixi run logs

status:
    pixi run status

pipeline action:
    pixi run pipeline -- -Action {{action}}

pipeline-state action state name="":
    pixi run pipeline -- -Action {{action}} -State {{state}} -Name {{name}}

pipeline-status:
    pixi run pipeline -- -Action status

cloud-state state name:
    pixi run pipeline -- -Action cloud-state -State {{state}} -Name {{name}}

cloud-ga:
    just cloud-state 13 georgia

showcase:
    pixi run showcase

validate state="13":
    pixi run validate -- --state {{state}}

validate-showcase:
    pixi run validate -- --parquet data/sample/showcase/parcels.parquet --pmtiles data/sample/showcase/parcels.pmtiles --fgb data/sample/showcase/parcels.fgb --bbox "-84.39,33.75,-84.386,33.753"

query-minio:
    pixi run query-minio

upload-minio state:
    pixi run pipeline -- -Action upload-minio -State {{state}}

psql:
    pixi run psql

tiger-indexes:
    pixi run tiger-indexes

serve-map:
    pixi run serve-map

verify:
    pixi run verify-browser

verify-map:
    pixi run verify-map

check:
    pixi run check

lint-ingest-api:
    pixi run lint-ingest-api

test-ingest-api:
    pixi run test-ingest-api

default:
    just --list
