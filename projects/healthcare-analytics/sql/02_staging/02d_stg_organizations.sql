-- =====================================================================
-- Stage 5 - Staging
-- Purpose : Clean hospitals (organizations), doctors (providers) and insurers (payers)
-- Reads   : raw.organizations, raw.providers, raw.payers
-- Creates : staging.organizations, staging.providers, staging.payers
--
-- Rules (from the exploratory data analysis):
--   * Hospital names are kept as in the source and a readable display name is added
--   * Fitchburg Outpatient Clinic is labelled as the network's cardiac centre: over 99%
--     of its 1,119 inpatient stays are cardiac, so it is real data, not an error
--   * Small-hospital grouping ("Other") is NOT done here; it belongs in the mart layer
--   * Payers get a simple category: Government, Private, Uninsured
-- =====================================================================

-- ---------------------------------------------------------------------
-- Organizations (hospitals and clinics)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.organizations CASCADE;

CREATE TABLE staging.organizations AS
SELECT
    id                                   AS organization_id,
    name                                 AS organization_name,
    -- readable name: Title Case, single spaces, no trailing punctuation, VA/LLC kept upper case
    REGEXP_REPLACE(REGEXP_REPLACE(
        TRIM(BOTH ' -,.' FROM REGEXP_REPLACE(INITCAP(name), '\s+', ' ', 'g')),
        '\mVa\M', 'VA', 'g'), '\mLlc\M', 'LLC', 'g')   AS organization_display_name,
    INITCAP(city)                        AS city,
    state,
    zip,
    lat::numeric                         AS latitude,
    lon::numeric                         AS longitude,
    CASE
        WHEN name = 'Fitchburg Outpatient Clinic' THEN 'Cardiac centre'
        ELSE 'General'
    END                                  AS facility_type
FROM raw.organizations;

ALTER TABLE staging.organizations ADD PRIMARY KEY (organization_id);

-- ---------------------------------------------------------------------
-- Providers (doctors)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.providers CASCADE;

CREATE TABLE staging.providers AS
SELECT
    id                                   AS provider_id,
    organization                         AS organization_id,
    name                                 AS provider_name,
    gender,
    INITCAP(speciality)                  AS specialty
FROM raw.providers;

ALTER TABLE staging.providers ADD PRIMARY KEY (provider_id);

-- ---------------------------------------------------------------------
-- Payers (insurers)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.payers CASCADE;

CREATE TABLE staging.payers AS
SELECT
    id                                   AS payer_id,
    CASE WHEN name = 'NO_INSURANCE' THEN 'No insurance' ELSE name END AS payer_name,
    CASE ownership
        WHEN 'GOVERNMENT'   THEN 'Government'
        WHEN 'PRIVATE'      THEN 'Private'
        WHEN 'NO_INSURANCE' THEN 'Uninsured'
        ELSE 'Other'
    END                                  AS payer_category
FROM raw.payers;

ALTER TABLE staging.payers ADD PRIMARY KEY (payer_id);

-- Check: 1,083 organizations (1 cardiac centre), 1,083 providers, 10 payers
SELECT 'organizations' AS table_name, COUNT(*) AS rows,
       COUNT(*) FILTER (WHERE facility_type = 'Cardiac centre') AS cardiac_centres
FROM staging.organizations
UNION ALL
SELECT 'providers', COUNT(*), NULL FROM staging.providers
UNION ALL
SELECT 'payers',    COUNT(*), NULL FROM staging.payers;
