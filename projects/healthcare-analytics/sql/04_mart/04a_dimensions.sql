-- =====================================================================
-- Stage 7 - Mart (star schema for Power BI)
-- Purpose : Analysis window settings, network bed capacity and the dimension tables
-- Reads   : staging.*
-- Creates : mart.analysis_window, mart.network_capacity, mart.dim_date,
--           mart.dim_patient, mart.dim_diagnosis, mart.dim_hospital,
--           mart.dim_provider, mart.dim_payer
--
-- Rules (decided after the exploratory data analysis):
--   * Analysis window = admissions from 2017-01-01 to 2025-12-31: nine full years
--     with consistent volume. Kept in ONE table (mart.analysis_window) so changing
--     the window is a one-line edit
--   * Hospitals with fewer than 30 episodes in the window are grouped as
--     "Other hospitals" so the dashboard does not compare rates built on a handful
--     of cases. The threshold is also kept in mart.analysis_window
--   * Dimensions are tables (not views) so they keep their keys and indexes and the
--     mart is a stable snapshot built by the pipeline
--
-- Bed capacity (Synthea has no bed counts):
--   * The network is treated as ONE bed pool. Synthea spreads about 64 patients a
--     night across 153 facilities, so almost every facility would have 1 to 3 beds
--     and its occupancy would swing on a single patient
--   * Network beds are sized so average occupancy over the window equals the target
--     occupancy (72%, the OECD average bed occupancy rate for 2023, OECD Health at a
--     Glance 2025):
--         beds = CEIL(average nightly network census in the window / target occupancy)
--   * Average nightly census counts days with no patients as zero
--   * Occupancy thresholds, also kept in mart.analysis_window:
--         85% = recommended safe level (Royal College of Emergency Medicine, NICE)
--         92% = maximum (NHS planning guidance)
--   * The success test uses the latest three years (from test_start_date), in
--     line with the three years of data used by the Medicare readmission programme
-- =====================================================================

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.analysis_window CASCADE;

CREATE TABLE mart.analysis_window AS
SELECT DATE '2017-01-01'  AS start_date,
       DATE '2025-12-31'  AS end_date,
       30                 AS min_episodes_named_hospital,
       DATE '2023-01-01'  AS test_start_date,
       0.72::numeric      AS target_occupancy,
       0.85::numeric      AS safe_occupancy,
       0.92::numeric      AS max_occupancy;

-- ---------------------------------------------------------------------
-- network_capacity: one row with the sized bed pool for the whole network
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.network_capacity CASCADE;

CREATE TABLE mart.network_capacity AS
WITH window_census AS (
    SELECT SUM(c.patients_in_bed) AS bed_days
    FROM staging.daily_census c
    CROSS JOIN mart.analysis_window w
    WHERE c.census_date BETWEEN w.start_date AND w.end_date
)
SELECT
    ROUND(wc.bed_days::numeric / (w.end_date - w.start_date + 1), 2)   AS avg_census_in_window,
    w.target_occupancy,
    CEIL(wc.bed_days::numeric / (w.end_date - w.start_date + 1)
         / w.target_occupancy)::int                                    AS beds
FROM window_census wc
CROSS JOIN mart.analysis_window w;

-- ---------------------------------------------------------------------
-- dim_date: one row per calendar day in the window
-- (month and day names come from arrays so they do not depend on the
--  language settings of the PostgreSQL server)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.dim_date CASCADE;

CREATE TABLE mart.dim_date AS
SELECT
    d::date                                                   AS date,
    EXTRACT(YEAR FROM d)::int                                 AS year,
    EXTRACT(QUARTER FROM d)::int                              AS quarter,
    'Q' || EXTRACT(QUARTER FROM d)::int                       AS quarter_label,
    EXTRACT(MONTH FROM d)::int                                AS month_number,
    (ARRAY['Jan','Feb','Mar','Apr','May','Jun',
           'Jul','Aug','Sep','Oct','Nov','Dec'])[EXTRACT(MONTH FROM d)::int] AS month_short,
    (ARRAY['January','February','March','April','May','June','July',
           'August','September','October','November','December'])[EXTRACT(MONTH FROM d)::int] AS month_name,
    DATE_TRUNC('month', d)::date                              AS month_start,
    TO_CHAR(d, 'YYYY-MM')                                     AS year_month,
    EXTRACT(ISODOW FROM d)::int                               AS day_of_week,
    (ARRAY['Monday','Tuesday','Wednesday','Thursday',
           'Friday','Saturday','Sunday'])[EXTRACT(ISODOW FROM d)::int] AS day_name,
    (EXTRACT(ISODOW FROM d) IN (6, 7))                        AS is_weekend
FROM mart.analysis_window w
CROSS JOIN generate_series(w.start_date, w.end_date, INTERVAL '1 day') AS d;

ALTER TABLE mart.dim_date ADD PRIMARY KEY (date);

-- ---------------------------------------------------------------------
-- dim_patient
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.dim_patient CASCADE;

CREATE TABLE mart.dim_patient AS
SELECT
    patient_id,
    CASE gender WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female' ELSE 'Unknown' END AS gender,
    birth_date,
    EXTRACT(YEAR FROM birth_date)::int  AS birth_year,
    is_deceased,
    marital_status,
    city,
    county
FROM staging.patients;

ALTER TABLE mart.dim_patient ADD PRIMARY KEY (patient_id);

-- ---------------------------------------------------------------------
-- dim_diagnosis: one row per primary diagnosis, with its group
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.dim_diagnosis CASCADE;

CREATE TABLE mart.dim_diagnosis AS
SELECT
    DENSE_RANK() OVER (ORDER BY diagnosis_group, primary_diagnosis) AS diagnosis_key,
    primary_diagnosis,
    REGEXP_REPLACE(primary_diagnosis,
                   '\s*\((disorder|situation|finding|procedure)\)$', '') AS diagnosis_label,
    diagnosis_group,
    is_planned_treatment
FROM (
    SELECT DISTINCT primary_diagnosis, diagnosis_group, is_planned_treatment
    FROM staging.episodes
) d;

ALTER TABLE mart.dim_diagnosis ADD PRIMARY KEY (diagnosis_key);
ALTER TABLE mart.dim_diagnosis ADD UNIQUE (primary_diagnosis);

-- ---------------------------------------------------------------------
-- dim_hospital: facilities with inpatient episodes, small ones grouped
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.dim_hospital CASCADE;

CREATE TABLE mart.dim_hospital AS
WITH window_episodes AS (
    SELECT e.organization_id, COUNT(*) AS episodes
    FROM staging.episodes e
    CROSS JOIN mart.analysis_window w
    WHERE e.admit_date BETWEEN w.start_date AND w.end_date
    GROUP BY e.organization_id
)
SELECT
    o.organization_id,
    o.organization_display_name                                 AS hospital_name,
    o.city,
    o.facility_type,
    COALESCE(we.episodes, 0)                                    AS episodes_in_window,
    CASE WHEN COALESCE(we.episodes, 0) >= w.min_episodes_named_hospital
         THEN o.organization_display_name
         ELSE 'Other hospitals' END                             AS hospital_group,
    o.latitude,
    o.longitude
FROM (SELECT DISTINCT organization_id FROM staging.episodes) h
JOIN staging.organizations o ON o.organization_id = h.organization_id
LEFT JOIN window_episodes we ON we.organization_id = h.organization_id
CROSS JOIN mart.analysis_window w;

ALTER TABLE mart.dim_hospital ADD PRIMARY KEY (organization_id);

-- ---------------------------------------------------------------------
-- dim_provider: doctors who led at least one episode
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.dim_provider CASCADE;

CREATE TABLE mart.dim_provider AS
SELECT
    p.provider_id,
    p.provider_name,
    p.specialty,
    p.gender
FROM staging.providers p
WHERE p.provider_id IN (SELECT DISTINCT provider_id FROM staging.episodes);

ALTER TABLE mart.dim_provider ADD PRIMARY KEY (provider_id);

-- ---------------------------------------------------------------------
-- dim_payer
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.dim_payer CASCADE;

CREATE TABLE mart.dim_payer AS
SELECT payer_id, payer_name, payer_category
FROM staging.payers;

ALTER TABLE mart.dim_payer ADD PRIMARY KEY (payer_id);

-- Check: dimension sizes
SELECT 'dim_date'      AS dimension, COUNT(*) AS rows FROM mart.dim_date
UNION ALL SELECT 'dim_patient',   COUNT(*) FROM mart.dim_patient
UNION ALL SELECT 'dim_diagnosis', COUNT(*) FROM mart.dim_diagnosis
UNION ALL SELECT 'dim_hospital',  COUNT(*) FROM mart.dim_hospital
UNION ALL SELECT 'dim_provider',  COUNT(*) FROM mart.dim_provider
UNION ALL SELECT 'dim_payer',     COUNT(*) FROM mart.dim_payer;

-- Check: which hospitals are shown by name on the dashboard
SELECT hospital_group, facility_type, episodes_in_window
FROM mart.dim_hospital
WHERE hospital_group <> 'Other hospitals'
UNION ALL
SELECT 'Other hospitals (' || COUNT(*) || ' facilities)', 'General', SUM(episodes_in_window)
FROM mart.dim_hospital
WHERE hospital_group = 'Other hospitals'
ORDER BY episodes_in_window DESC;

-- Check: the sized network bed pool
SELECT avg_census_in_window, target_occupancy, beds
FROM mart.network_capacity;
