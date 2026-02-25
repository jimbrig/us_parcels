-- etl_raw_to_parcel.sql
-- transforms parcel_raw (ogr2ogr import) into normalized parcels.parcel schema
-- idempotent: truncates target then inserts

BEGIN;

TRUNCATE parcels.parcel RESTART IDENTITY;

-- use coalesce chain for parcel_id: parcelid -> parcelid2 -> lrid
-- dedup on (geoid, resolved_parcel_id) keeping row with most attribute coverage
INSERT INTO parcels.parcel (
    parcel_id, parcel_id_alt, geoid,
    tax_account_num, tax_year,
    use_code, use_description, zoning_code, zoning_description,
    num_buildings, num_units, year_built, num_floors,
    building_sqft, bedrooms, half_baths, full_baths,
    improvement_value, land_value, agricultural_value, total_value,
    assessed_acres,
    sale_amount, sale_date,
    owner_name, owner_address, owner_city, owner_state, owner_zip,
    parcel_address, parcel_city, parcel_state, parcel_zip,
    legal_description,
    plss_township, plss_section, plss_quarter_section, plss_range, plss_description,
    plat_book, plat_page, plat_block, plat_lot,
    source_updated, source_version,
    centroid, surface_point, geom
)
SELECT
    resolved_id,
    r.parcelid2,
    r.geoid,
    r.taxacctnum,
    r.taxyear::smallint,
    r.usecode,
    r.usedesc,
    r.zoningcode,
    r.zoningdesc,
    r.numbldgs::smallint,
    r.numunits::smallint,
    r.yearbuilt::smallint,
    r.numfloors::smallint,
    r.bldgsqft,
    r.bedrooms::smallint,
    r.halfbaths::smallint,
    r.fullbaths::smallint,
    r.imprvalue,
    r.landvalue,
    r.agvalue,
    r.totalvalue,
    r.assdacres::numeric(10,4),
    r.saleamt,
    r.saledate,
    r.ownername,
    r.owneraddr,
    r.ownercity,
    r.ownerstate,
    r.ownerzip,
    r.parceladdr,
    r.parcelcity,
    r.parcelstate,
    r.parcelzip,
    r.legaldesc,
    r.township,
    r.section,
    r.qtrsection,
    r.range,
    r.plssdesc,
    r.book,
    r.page,
    r.block,
    r.lot,
    r.updated::date,
    r.lrversion,
    CASE WHEN r.centroidx IS NOT NULL AND r.centroidy IS NOT NULL
         THEN ST_SetSRID(ST_MakePoint(r.centroidx, r.centroidy), 4326)
    END,
    CASE WHEN r.surfpointx IS NOT NULL AND r.surfpointy IS NOT NULL
         THEN ST_SetSRID(ST_MakePoint(r.surfpointx, r.surfpointy), 4326)
    END,
    ST_Multi(r.geom)
FROM (
    SELECT *,
        COALESCE(parcelid, parcelid2, lrid::text) as resolved_id,
        ROW_NUMBER() OVER (
            PARTITION BY geoid, COALESCE(parcelid, parcelid2, lrid::text)
            ORDER BY
                (CASE WHEN totalvalue IS NOT NULL THEN 1 ELSE 0 END
                 + CASE WHEN yearbuilt IS NOT NULL THEN 1 ELSE 0 END
                 + CASE WHEN parceladdr IS NOT NULL THEN 1 ELSE 0 END
                 + CASE WHEN ownername IS NOT NULL THEN 1 ELSE 0 END) DESC,
                lrid DESC
        ) as rn
    FROM parcels.parcel_raw
    WHERE geoid IS NOT NULL
) r
WHERE r.rn = 1;

-- coverage view on normalized table (complements the raw view)
CREATE OR REPLACE VIEW parcels.parcel_coverage AS
SELECT
    substring(p.geoid, 1, 2) as statefp,
    substring(p.geoid, 3, 3) as countyfp,
    p.geoid,
    s.state_abbr,
    c.county_name,
    count(*) as total_parcels,
    round(100.0 * count(p.parcel_address) / count(*), 1) as pct_address,
    round(100.0 * count(p.owner_name) / count(*), 1) as pct_owner,
    round(100.0 * count(p.total_value) / count(*), 1) as pct_value,
    round(100.0 * count(p.year_built) / count(*), 1) as pct_yearbuilt,
    round(100.0 * count(p.use_description) / count(*), 1) as pct_usedesc,
    round(100.0 * count(p.sale_amount) / count(*), 1) as pct_saleamt,
    round(100.0 * count(p.building_sqft) / count(*), 1) as pct_bldgsqft,
    round(100.0 * count(p.zoning_code) / count(*), 1) as pct_zoning,
    round(100.0 * count(p.legal_description) / count(*), 1) as pct_legal
FROM parcels.parcel p
JOIN parcels.states s ON substring(p.geoid, 1, 2) = s.statefp
LEFT JOIN parcels.counties c ON p.geoid = c.geoid
GROUP BY p.geoid, s.state_abbr, c.county_name
ORDER BY p.geoid;

COMMIT;
