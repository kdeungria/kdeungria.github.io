-- =====================================================================
-- Stage 6 - Business logic
-- Purpose : Merge same-day and overlapping stays into episodes of care, with LOS
-- Reads   : staging.inpatient_stays
-- Creates : staging.stay_episode_map  (one row per stay -> its episode)
--           staging.episodes          (one row per episode of care)
--
-- Rules (from the exploratory data analysis):
--   * A stay joins the previous episode when it starts on or before the latest
--     discharge date so far for that patient (same-day returns and overlaps).
--     These were cardiac pathways (workup -> surgery) at the same hospital, i.e.
--     one episode of care, not a readmission
--   * Episode LOS = last discharge date - first admission date, minimum 1 day
--   * Episode hospital, doctor, payer and diagnosis come from the FIRST stay
--     (the reason the patient was admitted)
--   * Costs are summed across the stays in the episode
--
-- Technique: "gaps and islands" with window functions
--   1. running MAX(discharge_date) of the patient's earlier stays
--   2. a stay starts a new episode when it begins after that running max
--   3. a running SUM of those starts numbers the episodes
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Map every stay to an episode
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.stay_episode_map CASCADE;

CREATE TABLE staging.stay_episode_map AS
WITH ordered AS (
    SELECT
        encounter_id,
        patient_id,
        admit_ts,
        admit_date,
        discharge_date,
        MAX(discharge_date) OVER (
            PARTITION BY patient_id
            ORDER BY admit_ts, encounter_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prev_max_discharge
    FROM staging.inpatient_stays
),
flagged AS (
    SELECT *,
           CASE WHEN prev_max_discharge IS NULL
                  OR admit_date > prev_max_discharge THEN 1 ELSE 0 END AS starts_new_episode
    FROM ordered
),
numbered AS (
    SELECT *,
           SUM(starts_new_episode) OVER (
               PARTITION BY patient_id
               ORDER BY admit_ts, encounter_id
           ) AS episode_number
    FROM flagged
)
SELECT
    encounter_id,
    patient_id,
    DENSE_RANK() OVER (ORDER BY patient_id, episode_number)       AS episode_id,
    episode_number,
    ROW_NUMBER() OVER (PARTITION BY patient_id, episode_number
                       ORDER BY admit_ts, encounter_id)          AS stay_order_in_episode
FROM numbered;

ALTER TABLE staging.stay_episode_map ADD PRIMARY KEY (encounter_id);
CREATE INDEX ix_stg_map_episode ON staging.stay_episode_map (episode_id);

-- ---------------------------------------------------------------------
-- 2. One row per episode
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.episodes CASCADE;

CREATE TABLE staging.episodes AS
SELECT
    m.episode_id,
    m.patient_id,
    m.episode_number,
    MIN(s.admit_ts)                                         AS admit_ts,
    MAX(s.discharge_ts)                                     AS discharge_ts,
    MIN(s.admit_date)                                       AS admit_date,
    MAX(s.discharge_date)                                   AS discharge_date,
    GREATEST(MAX(s.discharge_date) - MIN(s.admit_date), 1)  AS los_days,
    COUNT(*)                                                AS stays_in_episode,
    -- attributes of the first stay
    MAX(s.encounter_id)      FILTER (WHERE m.stay_order_in_episode = 1) AS first_encounter_id,
    MAX(s.organization_id)   FILTER (WHERE m.stay_order_in_episode = 1) AS organization_id,
    MAX(s.provider_id)       FILTER (WHERE m.stay_order_in_episode = 1) AS provider_id,
    MAX(s.payer_id)          FILTER (WHERE m.stay_order_in_episode = 1) AS payer_id,
    MAX(s.primary_diagnosis) FILTER (WHERE m.stay_order_in_episode = 1) AS primary_diagnosis,
    MAX(s.diagnosis_group)   FILTER (WHERE m.stay_order_in_episode = 1) AS diagnosis_group,
    BOOL_OR(s.is_planned_treatment) FILTER (WHERE m.stay_order_in_episode = 1) AS is_planned_treatment,
    -- costs across all stays in the episode
    SUM(s.total_cost)                                       AS total_cost,
    SUM(s.payer_coverage)                                   AS payer_coverage,
    SUM(s.patient_paid)                                     AS patient_paid
FROM staging.stay_episode_map m
JOIN staging.inpatient_stays s ON s.encounter_id = m.encounter_id
GROUP BY m.episode_id, m.patient_id, m.episode_number;

ALTER TABLE staging.episodes ADD PRIMARY KEY (episode_id);
CREATE INDEX ix_stg_episodes_patient ON staging.episodes (patient_id, admit_ts);
CREATE INDEX ix_stg_episodes_org     ON staging.episodes (organization_id);

-- Check 1: every stay is mapped exactly once, and stays fold into fewer episodes
SELECT
    (SELECT COUNT(*) FROM staging.inpatient_stays)                     AS stays,
    (SELECT COUNT(*) FROM staging.stay_episode_map)                    AS stays_mapped,
    (SELECT COUNT(*) FROM staging.episodes)                            AS episodes,
    (SELECT COUNT(*) FROM staging.episodes WHERE stays_in_episode > 1) AS merged_episodes,
    (SELECT MAX(stays_in_episode) FROM staging.episodes)               AS max_stays_in_episode;

-- Check 2: costs are preserved (both totals must be equal) and LOS by stay vs episode
SELECT
    (SELECT SUM(total_cost) FROM staging.inpatient_stays)  AS stay_total_cost,
    (SELECT SUM(total_cost) FROM staging.episodes)         AS episode_total_cost,
    (SELECT ROUND(AVG(los_days), 2) FROM staging.inpatient_stays) AS avg_los_per_stay,
    (SELECT ROUND(AVG(los_days), 2) FROM staging.episodes)        AS avg_los_per_episode,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY los_days)
       FROM staging.episodes)                                      AS median_los_per_episode;
