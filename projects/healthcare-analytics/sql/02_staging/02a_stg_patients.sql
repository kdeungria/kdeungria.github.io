-- =====================================================================
-- Stage 5 - Staging
-- Purpose : Clean patients: proper types, consistent names, no direct identifiers
-- Reads   : raw.patients
-- Creates : staging.patients
--
-- Rules (from the exploratory data analysis):
--   * Dates converted from text to DATE
--   * Direct identifiers dropped (ssn, drivers, passport, names, address, lat/lon):
--     synthetic, but not needed for analysis and good data-handling practice
--   * One row per patient (no duplicate ids were found in raw)
-- =====================================================================

DROP TABLE IF EXISTS staging.patients CASCADE;

CREATE TABLE staging.patients AS
SELECT
    id                                   AS patient_id,
    birthdate::date                      AS birth_date,
    deathdate::date                      AS death_date,
    (deathdate IS NOT NULL)              AS is_deceased,
    gender,
    marital                              AS marital_status,
    city,
    county,
    state
FROM raw.patients;

ALTER TABLE staging.patients ADD PRIMARY KEY (patient_id);

-- Check: patient and deceased counts (expected values are in the golden-number checks in python/03_run_sql.py)
SELECT COUNT(*)                          AS patients,
       COUNT(*) FILTER (WHERE is_deceased) AS deceased
FROM staging.patients;
