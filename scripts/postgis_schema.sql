-- postgis_schema.sql - Normalized PostGIS schema for US parcel data
-- Run with: psql -d parcels -f scripts/postgis_schema.sql

-- enable extensions
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- create schema
DROP SCHEMA IF EXISTS parcels CASCADE;
CREATE SCHEMA parcels;

-- lookup: states
CREATE TABLE parcels.states (
    statefp CHAR(2) PRIMARY KEY,
    state_name VARCHAR(50) NOT NULL,
    state_abbr CHAR(2) NOT NULL
);

INSERT INTO parcels.states (statefp, state_name, state_abbr) VALUES
('01', 'Alabama', 'AL'), ('02', 'Alaska', 'AK'), ('04', 'Arizona', 'AZ'),
('05', 'Arkansas', 'AR'), ('06', 'California', 'CA'), ('08', 'Colorado', 'CO'),
('09', 'Connecticut', 'CT'), ('10', 'Delaware', 'DE'), ('11', 'District of Columbia', 'DC'),
('12', 'Florida', 'FL'), ('13', 'Georgia', 'GA'), ('15', 'Hawaii', 'HI'),
('16', 'Idaho', 'ID'), ('17', 'Illinois', 'IL'), ('18', 'Indiana', 'IN'),
('19', 'Iowa', 'IA'), ('20', 'Kansas', 'KS'), ('21', 'Kentucky', 'KY'),
('22', 'Louisiana', 'LA'), ('23', 'Maine', 'ME'), ('24', 'Maryland', 'MD'),
('25', 'Massachusetts', 'MA'), ('26', 'Michigan', 'MI'), ('27', 'Minnesota', 'MN'),
('28', 'Mississippi', 'MS'), ('29', 'Missouri', 'MO'), ('30', 'Montana', 'MT'),
('31', 'Nebraska', 'NE'), ('32', 'Nevada', 'NV'), ('33', 'New Hampshire', 'NH'),
('34', 'New Jersey', 'NJ'), ('35', 'New Mexico', 'NM'), ('36', 'New York', 'NY'),
('37', 'North Carolina', 'NC'), ('38', 'North Dakota', 'ND'), ('39', 'Ohio', 'OH'),
('40', 'Oklahoma', 'OK'), ('41', 'Oregon', 'OR'), ('42', 'Pennsylvania', 'PA'),
('44', 'Rhode Island', 'RI'), ('45', 'South Carolina', 'SC'), ('46', 'South Dakota', 'SD'),
('47', 'Tennessee', 'TN'), ('48', 'Texas', 'TX'), ('49', 'Utah', 'UT'),
('50', 'Vermont', 'VT'), ('51', 'Virginia', 'VA'), ('53', 'Washington', 'WA'),
('54', 'West Virginia', 'WV'), ('55', 'Wisconsin', 'WI'), ('56', 'Wyoming', 'WY'),
('60', 'American Samoa', 'AS'), ('66', 'Guam', 'GU'), ('69', 'Northern Mariana Islands', 'MP'),
('72', 'Puerto Rico', 'PR'), ('78', 'Virgin Islands', 'VI');

-- lookup: counties (populated during ETL)
CREATE TABLE parcels.counties (
    geoid CHAR(5) PRIMARY KEY,
    statefp CHAR(2) REFERENCES parcels.states(statefp),
    countyfp CHAR(3) NOT NULL,
    county_name VARCHAR(100)
);

-- lookup: land use categories
CREATE TABLE parcels.land_use_categories (
    category_id SERIAL PRIMARY KEY,
    category_name VARCHAR(50) NOT NULL UNIQUE
);

INSERT INTO parcels.land_use_categories (category_name) VALUES
('residential'), ('commercial'), ('industrial'), ('agricultural'),
('vacant'), ('exempt'), ('mixed_use'), ('other');

-- main parcel table
CREATE TABLE parcels.parcel (
    id BIGSERIAL PRIMARY KEY,
    
    -- identifiers
    parcel_id VARCHAR(100) NOT NULL,
    parcel_id_alt VARCHAR(100),
    geoid CHAR(5) NOT NULL,
    
    -- tax info
    tax_account_num VARCHAR(50),
    tax_year SMALLINT,
    
    -- land use
    use_code VARCHAR(20),
    use_description VARCHAR(255),
    zoning_code VARCHAR(50),
    zoning_description VARCHAR(255),
    
    -- building info
    num_buildings SMALLINT,
    num_units SMALLINT,
    year_built SMALLINT,
    num_floors SMALLINT,
    building_sqft INTEGER,
    bedrooms SMALLINT,
    half_baths SMALLINT,
    full_baths SMALLINT,
    
    -- valuation
    improvement_value BIGINT,
    land_value BIGINT,
    agricultural_value BIGINT,
    total_value BIGINT,
    assessed_acres NUMERIC(10,4),
    
    -- sale info
    sale_amount BIGINT,
    sale_date DATE,
    
    -- owner info
    owner_name VARCHAR(255),
    owner_address VARCHAR(500),
    owner_city VARCHAR(100),
    owner_state VARCHAR(50),
    owner_zip VARCHAR(20),
    
    -- parcel address
    parcel_address VARCHAR(500),
    parcel_city VARCHAR(100),
    parcel_state VARCHAR(50),
    parcel_zip VARCHAR(20),
    
    -- legal description
    legal_description TEXT,
    
    -- PLSS fields
    plss_township VARCHAR(20),
    plss_section VARCHAR(20),
    plss_quarter_section VARCHAR(20),
    plss_range VARCHAR(20),
    plss_description VARCHAR(255),
    
    -- plat info
    plat_book VARCHAR(50),
    plat_page VARCHAR(50),
    plat_block VARCHAR(50),
    plat_lot VARCHAR(50),
    
    -- metadata
    source_updated DATE,
    source_version VARCHAR(20),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- geometry columns
    centroid GEOMETRY(POINT, 4326),
    surface_point GEOMETRY(POINT, 4326),
    geom GEOMETRY(MULTIPOLYGON, 4326),
    
    -- constraints
    CONSTRAINT unique_parcel UNIQUE (geoid, parcel_id)
);

-- indexes for common query patterns
CREATE INDEX idx_parcel_geoid ON parcels.parcel(geoid);
CREATE INDEX idx_parcel_statefp ON parcels.parcel(SUBSTRING(geoid, 1, 2));
CREATE INDEX idx_parcel_owner_name ON parcels.parcel USING gin(owner_name gin_trgm_ops);
CREATE INDEX idx_parcel_address ON parcels.parcel USING gin(parcel_address gin_trgm_ops);
CREATE INDEX idx_parcel_geom ON parcels.parcel USING gist(geom);
CREATE INDEX idx_parcel_centroid ON parcels.parcel USING gist(centroid);
CREATE INDEX idx_parcel_total_value ON parcels.parcel(total_value) WHERE total_value IS NOT NULL;
CREATE INDEX idx_parcel_year_built ON parcels.parcel(year_built) WHERE year_built IS NOT NULL;
CREATE INDEX idx_parcel_sale_date ON parcels.parcel(sale_date) WHERE sale_date IS NOT NULL;

-- view: parcels with state/county names
CREATE VIEW parcels.parcel_full AS
SELECT 
    p.*,
    s.state_name,
    s.state_abbr,
    c.county_name
FROM parcels.parcel p
JOIN parcels.states s ON SUBSTRING(p.geoid, 1, 2) = s.statefp
LEFT JOIN parcels.counties c ON p.geoid = c.geoid;

-- function: search parcels by address
CREATE OR REPLACE FUNCTION parcels.search_by_address(search_term TEXT, limit_rows INT DEFAULT 100)
RETURNS SETOF parcels.parcel AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM parcels.parcel
    WHERE parcel_address ILIKE '%' || search_term || '%'
    ORDER BY similarity(parcel_address, search_term) DESC
    LIMIT limit_rows;
END;
$$ LANGUAGE plpgsql;

-- function: search parcels by owner
CREATE OR REPLACE FUNCTION parcels.search_by_owner(search_term TEXT, limit_rows INT DEFAULT 100)
RETURNS SETOF parcels.parcel AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM parcels.parcel
    WHERE owner_name ILIKE '%' || search_term || '%'
    ORDER BY similarity(owner_name, search_term) DESC
    LIMIT limit_rows;
END;
$$ LANGUAGE plpgsql;

-- function: get parcels in bounding box
CREATE OR REPLACE FUNCTION parcels.get_parcels_in_bbox(
    min_lon FLOAT, min_lat FLOAT, max_lon FLOAT, max_lat FLOAT,
    limit_rows INT DEFAULT 1000
)
RETURNS SETOF parcels.parcel AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM parcels.parcel
    WHERE geom && ST_MakeEnvelope(min_lon, min_lat, max_lon, max_lat, 4326)
    LIMIT limit_rows;
END;
$$ LANGUAGE plpgsql;

-- grant permissions (adjust as needed)
-- GRANT USAGE ON SCHEMA parcels TO parcels_reader;
-- GRANT SELECT ON ALL TABLES IN SCHEMA parcels TO parcels_reader;

COMMENT ON TABLE parcels.parcel IS 'US parcel records from LandRecords.us, normalized schema';
COMMENT ON COLUMN parcels.parcel.geoid IS 'Combined state+county FIPS code (5 digits)';
COMMENT ON COLUMN parcels.parcel.centroid IS 'Geographic center of parcel (may be outside polygon for C-shaped parcels)';
COMMENT ON COLUMN parcels.parcel.surface_point IS 'Point guaranteed to be inside the parcel surface';
