-- =====================================================================
-- Stage 6 - Business logic
-- Purpose : In-hospital and 30-day post-discharge mortality flags
-- Reads   : staging.episodes, staging.patients
-- Creates : staging.episode_mortality (one row per episode)
--
-- Rules (from the exploratory data analysis):
--   * Death dates have no time, so comparisons are by calendar date
--   * Died in hospital  = death date between admission and discharge date
--     (same rule as the readmission denominator in 03b)
--   * Died within 30 days = death date 1 to 30 days after discharge
--   * Counts are small (about 65 in-hospital deaths), so mortality is meant to be
--     reported overall and by diagnosis group, not by individual hospital or doctor
-- =====================================================================

DROP TABLE IF EXISTS staging.episode_mortality CASCADE;

CREATE TABLE staging.episode_mortality AS
SELECT
    e.episode_id,
    p.death_date,
    (p.death_date BETWEEN e.admit_date AND e.discharge_date) IS TRUE        AS died_in_hospital,
    (p.death_date >  e.discharge_date
     AND p.death_date <= e.discharge_date + 30) IS TRUE                     AS died_within_30d,
    CASE WHEN p.death_date > e.discharge_date
         THEN p.death_date - e.discharge_date END                           AS days_discharge_to_death
FROM staging.episodes e
JOIN staging.patients p ON p.patient_id = e.patient_id;

ALTER TABLE staging.episode_mortality ADD PRIMARY KEY (episode_id);

-- Check 1: overall mortality
SELECT
    COUNT(*)                                       AS episodes,
    COUNT(*) FILTER (WHERE died_in_hospital)       AS in_hospital_deaths,
    COUNT(*) FILTER (WHERE died_within_30d)        AS deaths_within_30d,
    ROUND(100.0 * COUNT(*) FILTER (WHERE died_in_hospital) / COUNT(*), 2) AS in_hospital_mortality_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE died_within_30d)
          / NULLIF(COUNT(*) FILTER (WHERE NOT died_in_hospital), 0), 2)  AS mortality_30d_pct
FROM staging.episode_mortality;

-- Check 2: in-hospital deaths by diagnosis group
SELECT e.diagnosis_group,
       COUNT(*)                                   AS episodes,
       COUNT(*) FILTER (WHERE m.died_in_hospital) AS in_hospital_deaths
FROM staging.episode_mortality m
JOIN staging.episodes e ON e.episode_id = m.episode_id
GROUP BY e.diagnosis_group
ORDER BY in_hospital_deaths DESC, episodes DESC;
