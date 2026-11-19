-- =====================================================================
-- Stage 5 - Staging
-- Purpose : One clean row per inpatient stay, with types, LOS and diagnosis groups
-- Reads   : raw.encounters
-- Creates : staging.inpatient_stays
--
-- Rules (from the exploratory data analysis):
--   * Inpatient encounters only
--   * Timestamps are UTC ('Z'). Dates are taken AT TIME ZONE 'UTC' so they do not
--     shift with the timezone setting of the computer running PostgreSQL
--   * Length of stay = calendar days between admission and discharge, minimum 1
--   * Primary diagnosis = the encounter's own reason (reasondescription), because
--     61% of stays have no row in the conditions table. One blank reason -> 'Unknown'
--   * Diagnosis groups make the 37 admission reasons readable on a dashboard
--   * is_planned_treatment flags lung cancer stays: the 28-35 day returns are
--     scheduled treatment cycles and are excluded from readmissions in Stage 6
--   * Same-day and overlapping stays are NOT merged here; that happens in Stage 6
--     (episode logic), so this table stays a faithful copy of the source stays
-- =====================================================================

DROP TABLE IF EXISTS staging.inpatient_stays CASCADE;

CREATE TABLE staging.inpatient_stays AS
WITH typed AS (
    SELECT
        id                                         AS encounter_id,
        patient                                    AS patient_id,
        organization                               AS organization_id,
        provider                                   AS provider_id,
        payer                                      AS payer_id,
        start::timestamptz                         AS admit_ts,
        stop::timestamptz                          AS discharge_ts,
        code                                       AS encounter_code,
        description                                AS encounter_type,
        COALESCE(NULLIF(reasoncode, ''), 'UNKNOWN') AS primary_dx_code,
        COALESCE(NULLIF(TRIM(REGEXP_REPLACE(reasondescription, '\s+', ' ', 'g')), ''), 'Unknown')
                                                   AS primary_diagnosis,
        base_encounter_cost::numeric(12, 2)        AS base_cost,
        total_claim_cost::numeric(12, 2)           AS total_cost,
        payer_coverage::numeric(12, 2)             AS payer_coverage
    FROM raw.encounters
    WHERE encounterclass = 'inpatient'
)
SELECT
    encounter_id,
    patient_id,
    organization_id,
    provider_id,
    payer_id,
    admit_ts,
    discharge_ts,
    (admit_ts     AT TIME ZONE 'UTC')::date        AS admit_date,
    (discharge_ts AT TIME ZONE 'UTC')::date        AS discharge_date,
    GREATEST((discharge_ts AT TIME ZONE 'UTC')::date
             - (admit_ts   AT TIME ZONE 'UTC')::date, 1) AS los_days,
    ROUND((EXTRACT(EPOCH FROM discharge_ts - admit_ts) / 3600.0)::numeric, 1) AS los_hours,
    encounter_code,
    encounter_type,
    primary_dx_code,
    primary_diagnosis,
    CASE
        WHEN primary_diagnosis ILIKE '%of lung%'                          THEN 'Lung cancer'
        WHEN primary_diagnosis ~* 'carcinoma|neoplasm|leukemia|myeloma'   THEN 'Other cancer'
        WHEN primary_diagnosis ~* 'coronary|heart|myocardial|aortic valve|preinfarction'
                                                                          THEN 'Cardiac'
        WHEN primary_diagnosis ~* 'drug abuse'                            THEN 'Substance use'
        WHEN primary_diagnosis ~* 'sterilization|pregnancy'               THEN 'Obstetric and gynecologic'
        WHEN primary_diagnosis ~* 'transplantation'                       THEN 'Transplant'
        WHEN primary_diagnosis ~* 'severe acute respiratory|emphysema|bronchitis'
                                                                          THEN 'Respiratory and COVID-19'
        WHEN primary_diagnosis ~* 'ligament|tendon|artificial joint'      THEN 'Musculoskeletal'
        WHEN primary_diagnosis ~* 'appendicitis'                          THEN 'General surgery'
        WHEN primary_diagnosis ~* 'sleep|neuropathy|meningomyelocele'     THEN 'Neurological and sleep'
        WHEN primary_diagnosis = 'Unknown'                                THEN 'Unknown'
        ELSE 'Other'
    END                                            AS diagnosis_group,
    (primary_diagnosis ILIKE '%of lung%')          AS is_planned_treatment,
    base_cost,
    total_cost,
    payer_coverage,
    total_cost - payer_coverage                    AS patient_paid
FROM typed;

ALTER TABLE staging.inpatient_stays ADD PRIMARY KEY (encounter_id);
CREATE INDEX ix_stg_stays_patient_admit ON staging.inpatient_stays (patient_id, admit_ts);
CREATE INDEX ix_stg_stays_org           ON staging.inpatient_stays (organization_id);

-- Check 1: stay count, with no LOS under 1 day
SELECT COUNT(*)                              AS stays,
       MIN(los_days)                         AS min_los,
       ROUND(AVG(los_days), 2)               AS avg_los,
       COUNT(*) FILTER (WHERE is_planned_treatment) AS planned_treatment_stays
FROM staging.inpatient_stays;

-- Check 2: every stay has a diagnosis group; 'Other' should be small
SELECT diagnosis_group, COUNT(*) AS stays
FROM staging.inpatient_stays
GROUP BY diagnosis_group
ORDER BY stays DESC;
