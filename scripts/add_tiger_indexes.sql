-- add spatial indexes to TIGER tables so Martin can serve them
-- run: psql postgresql://parcels:parcels@localhost:5432/parcels -f scripts/add_tiger_indexes.sql

CREATE INDEX IF NOT EXISTS idx_tiger_state_geom ON tiger.state USING gist(the_geom);
CREATE INDEX IF NOT EXISTS idx_tiger_county_geom ON tiger.county USING gist(the_geom);
CREATE INDEX IF NOT EXISTS idx_tiger_tract_geom ON tiger.tract USING gist(the_geom);
