-- =====================================================================
-- Stage 6 - Business logic
-- Purpose : 30-day unplanned readmission flags (Definition C)
-- Reads   : staging.episodes, staging.patients, raw.encounters (data end date)
-- Creates : staging.episode_readmissions (one row per episode)
--
-- Definition C (chosen after the exploratory data analysis):
--   * Unit of analysis = episode of care (same-day and overlapping stays already
--     merged in 03a, so they can never count as readmissions)
--   * Index episode (denominator) = patient discharged alive AND the data covers
--     the full 30 days after discharge
--   * Readmission (numerator) = the patient's NEXT episode starts 1 to 30 days after
--     the index discharge AND is not a planned lung cancer treatment cycle
--   * Planned returns within 30 days are kept as their own flag for transparency
--
-- Technique: LEAD() looks at the same patient's next episode
-- =====================================================================

DROP TABLE IF EXISTS staging.episode_readmissions CASCADE;

CREATE TABLE staging.episode_readmissions AS
WITH data_end AS (
    SELECT MAX((start::timestamptz AT TIME ZONE 'UTC')::date) AS last_data_date
    FROM raw.encounters
),
seq AS (
    SELECT
        e.episode_id,
        e.organization_id,
        e.admit_date,
        e.discharge_date,
        p.death_date,
        LEAD(e.episode_id)           OVER w AS next_episode_id,
        LEAD(e.admit_date)           OVER w AS next_admit_date,
        LEAD(e.organization_id)      OVER w AS next_organization_id,
        LEAD(e.diagnosis_group)      OVER w AS next_diagnosis_group,
        LEAD(e.is_planned_treatment) OVER w AS next_is_planned
    FROM staging.episodes e
    JOIN staging.patients p ON p.patient_id = e.patient_id
    WINDOW w AS (PARTITION BY e.patient_id ORDER BY e.admit_ts, e.episode_id)
),
base AS (
    SELECT
        s.*,
        s.next_admit_date - s.discharge_date                            AS days_to_next_admit,
        (s.death_date BETWEEN s.admit_date AND s.discharge_date) IS TRUE AS died_in_hospital,
        (s.discharge_date + 30 <= d.last_data_date)                     AS has_full_followup
    FROM seq s
    CROSS JOIN data_end d
)
SELECT
    episode_id,
    next_episode_id,
    next_admit_date,
    days_to_next_admit,
    next_diagnosis_group,
    COALESCE(next_is_planned, FALSE)                                AS next_is_planned,
    (next_organization_id = organization_id)                        AS next_at_same_hospital,
    died_in_hospital,
    has_full_followup,
    (NOT died_in_hospital AND has_full_followup)                    AS is_index_eligible,
    (NOT died_in_hospital AND has_full_followup
     AND days_to_next_admit BETWEEN 1 AND 30
     AND NOT COALESCE(next_is_planned, FALSE))                      AS is_readmitted_30d,
    (NOT died_in_hospital AND has_full_followup
     AND days_to_next_admit BETWEEN 1 AND 30
     AND COALESCE(next_is_planned, FALSE))                          AS is_planned_return_30d
FROM base;

ALTER TABLE staging.episode_readmissions ADD PRIMARY KEY (episode_id);

-- Check 1: headline readmission rate (all years)
SELECT
    COUNT(*)                                                     AS episodes,
    COUNT(*) FILTER (WHERE is_index_eligible)                    AS index_episodes,
    COUNT(*) FILTER (WHERE is_readmitted_30d)                    AS unplanned_readmissions,
    COUNT(*) FILTER (WHERE is_planned_return_30d)                AS planned_returns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_readmitted_30d)
          / NULLIF(COUNT(*) FILTER (WHERE is_index_eligible), 0), 2) AS readmission_rate_pct
FROM staging.episode_readmissions;

-- Check 2: what the unplanned readmissions are (diagnosis of the return episode)
SELECT next_diagnosis_group,
       COUNT(*) AS unplanned_readmissions
FROM staging.episode_readmissions
WHERE is_readmitted_30d
GROUP BY next_diagnosis_group
ORDER BY unplanned_readmissions DESC;
