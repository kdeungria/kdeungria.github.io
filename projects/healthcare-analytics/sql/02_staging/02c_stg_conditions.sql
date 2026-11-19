-- =====================================================================
-- Stage 5 - Staging
-- Purpose : Clean diagnoses (conditions) with proper types
-- Reads   : raw.conditions
-- Creates : staging.conditions
--
-- Rules (from the exploratory data analysis):
--   * Supporting context only. The primary diagnosis of a stay comes from the
--     encounter (staging.inpatient_stays.primary_diagnosis), because conditions are
--     recorded at the visit where they were first diagnosed, not at each admission
--   * Never join this table directly to stays for counts or costs: one stay can have
--     up to 6 conditions, which would multiply rows (fan-out)
--   * stop_date is NULL for conditions that are still active
-- =====================================================================

DROP TABLE IF EXISTS staging.conditions CASCADE;

CREATE TABLE staging.conditions AS
SELECT
    patient                                   AS patient_id,
    encounter                                 AS encounter_id,
    start::date                               AS start_date,
    stop::date                                AS stop_date,
    (stop IS NULL)                            AS is_active,
    system                                    AS code_system,
    code                                      AS condition_code,
    TRIM(REGEXP_REPLACE(description, '\s+', ' ', 'g')) AS condition
FROM raw.conditions;

CREATE INDEX ix_stg_conditions_patient   ON staging.conditions (patient_id);
CREATE INDEX ix_stg_conditions_encounter ON staging.conditions (encounter_id);

-- Check: row count should match raw.conditions (202,468)
SELECT COUNT(*)                           AS conditions,
       COUNT(DISTINCT patient_id)         AS patients_with_conditions,
       COUNT(*) FILTER (WHERE is_active)  AS active_conditions
FROM staging.conditions;
