-- =====================================================================
-- Stage 7 - Mart (star schema for Power BI)
-- Purpose : Fact tables for Power BI
-- Reads   : staging.episodes, staging.patients, staging.episode_readmissions,
--           staging.episode_mortality, staging.daily_census, mart dimensions,
--           mart.network_capacity
-- Creates : mart.fact_episode          (one row per episode admitted in the window)
--           mart.fact_daily_census     (one row per hospital per day with patients)
--           mart.fact_daily_occupancy  (one row per day in the window for the
--                                       network bed pool, including empty days)
--
-- Rules:
--   * Episodes are in the window by ADMISSION date. An episode admitted in late
--     December 2025 stays in even if it ends in January 2026, and its readmission
--     flag can still be checked because January 2026 data exists
--   * Flags are stored as 0/1 integers so Power BI can simply SUM them:
--       Readmission rate = SUM(is_readmitted_30d) / SUM(is_index_eligible)
--   * Flags are never blank. The readmission flags are blank in staging when a
--     patient has no later admission at all; that means "not readmitted", so it is
--     stored as 0. Otherwise measures such as COUNTROWS where the flag = 0 would
--     silently miss those episodes
--   * Census rows are in the window by CENSUS date (patients in a bed that day)
--   * Occupancy rate = network patients in a bed at the midnight count / network
--     beds (beds from mart.network_capacity, thresholds from mart.analysis_window)
--   * Foreign keys enforce the star schema: every fact row must find its dimensions
-- =====================================================================

-- ---------------------------------------------------------------------
-- fact_episode
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.fact_episode CASCADE;

CREATE TABLE mart.fact_episode AS
WITH base AS (
    SELECT
        e.*,
        EXTRACT(YEAR FROM AGE(e.admit_date, p.birth_date))::int AS age_at_admission
    FROM staging.episodes e
    JOIN staging.patients p ON p.patient_id = e.patient_id
    CROSS JOIN mart.analysis_window w
    WHERE e.admit_date BETWEEN w.start_date AND w.end_date
)
SELECT
    b.episode_id,
    -- keys to the dimensions
    b.patient_id,
    b.organization_id,
    b.provider_id,
    b.payer_id,
    dd.diagnosis_key,
    b.admit_date,
    b.discharge_date,
    -- length of stay
    b.los_days,
    CASE WHEN b.los_days = 1  THEN '1 day'
         WHEN b.los_days <= 3  THEN '2-3 days'
         WHEN b.los_days <= 7  THEN '4-7 days'
         WHEN b.los_days <= 14 THEN '8-14 days'
         ELSE '15+ days' END                                     AS los_band,
    CASE WHEN b.los_days = 1  THEN 1
         WHEN b.los_days <= 3  THEN 2
         WHEN b.los_days <= 7  THEN 3
         WHEN b.los_days <= 14 THEN 4
         ELSE 5 END                                              AS los_band_order,
    b.stays_in_episode,
    -- patient age at admission
    b.age_at_admission,
    CASE WHEN b.age_at_admission < 18 THEN '0-17'
         WHEN b.age_at_admission < 45 THEN '18-44'
         WHEN b.age_at_admission < 65 THEN '45-64'
         WHEN b.age_at_admission < 75 THEN '65-74'
         WHEN b.age_at_admission < 85 THEN '75-84'
         ELSE '85+' END                                          AS age_group,
    CASE WHEN b.age_at_admission < 18 THEN 1
         WHEN b.age_at_admission < 45 THEN 2
         WHEN b.age_at_admission < 65 THEN 3
         WHEN b.age_at_admission < 75 THEN 4
         WHEN b.age_at_admission < 85 THEN 5
         ELSE 6 END                                              AS age_group_order,
    -- cost
    b.total_cost,
    b.payer_coverage,
    b.patient_paid,
    -- flags (0/1)
    b.is_planned_treatment::int                                  AS is_planned_treatment,
    COALESCE(r.is_index_eligible::int, 0)                        AS is_index_eligible,
    COALESCE(r.is_readmitted_30d::int, 0)                        AS is_readmitted_30d,
    COALESCE(r.is_planned_return_30d::int, 0)                    AS is_planned_return_30d,
    CASE WHEN r.is_readmitted_30d THEN r.days_to_next_admit END  AS days_to_readmission,
    CASE WHEN r.is_readmitted_30d
         THEN r.next_at_same_hospital::int END                   AS readmitted_same_hospital,
    COALESCE(m.died_in_hospital::int, 0)                         AS died_in_hospital,
    COALESCE(m.died_within_30d::int, 0)                          AS died_within_30d
FROM base b
JOIN staging.episode_readmissions r ON r.episode_id = b.episode_id
JOIN staging.episode_mortality    m ON m.episode_id = b.episode_id
JOIN mart.dim_diagnosis          dd ON dd.primary_diagnosis = b.primary_diagnosis;

ALTER TABLE mart.fact_episode ADD PRIMARY KEY (episode_id);
ALTER TABLE mart.fact_episode ADD FOREIGN KEY (patient_id)      REFERENCES mart.dim_patient   (patient_id);
ALTER TABLE mart.fact_episode ADD FOREIGN KEY (organization_id) REFERENCES mart.dim_hospital  (organization_id);
ALTER TABLE mart.fact_episode ADD FOREIGN KEY (provider_id)     REFERENCES mart.dim_provider  (provider_id);
ALTER TABLE mart.fact_episode ADD FOREIGN KEY (payer_id)        REFERENCES mart.dim_payer     (payer_id);
ALTER TABLE mart.fact_episode ADD FOREIGN KEY (diagnosis_key)   REFERENCES mart.dim_diagnosis (diagnosis_key);
ALTER TABLE mart.fact_episode ADD FOREIGN KEY (admit_date)      REFERENCES mart.dim_date      (date);

-- ---------------------------------------------------------------------
-- fact_daily_census
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.fact_daily_census CASCADE;

CREATE TABLE mart.fact_daily_census AS
SELECT
    c.census_date,
    c.organization_id,
    c.patients_in_bed
FROM staging.daily_census c
CROSS JOIN mart.analysis_window w
WHERE c.census_date BETWEEN w.start_date AND w.end_date;

ALTER TABLE mart.fact_daily_census ADD PRIMARY KEY (census_date, organization_id);
ALTER TABLE mart.fact_daily_census ADD FOREIGN KEY (census_date)     REFERENCES mart.dim_date     (date);
ALTER TABLE mart.fact_daily_census ADD FOREIGN KEY (organization_id) REFERENCES mart.dim_hospital (organization_id);

-- ---------------------------------------------------------------------
-- fact_daily_occupancy: the network bed pool on every day of the window,
-- with days that had no patients filled in as zero
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS mart.fact_daily_occupancy CASCADE;

CREATE TABLE mart.fact_daily_occupancy AS
WITH daily AS (
    SELECT
        d.date                                                   AS census_date,
        COALESCE(SUM(c.patients_in_bed), 0)                      AS patients_in_bed
    FROM mart.dim_date d
    LEFT JOIN mart.fact_daily_census c ON c.census_date = d.date
    GROUP BY d.date
)
SELECT
    dy.census_date,
    dy.patients_in_bed,
    nc.beds,
    ROUND(dy.patients_in_bed::numeric / nc.beds, 4)              AS occupancy_rate,
    (dy.patients_in_bed::numeric / nc.beds > w.safe_occupancy)::int AS is_over_safe_level,
    (dy.patients_in_bed::numeric / nc.beds > w.max_occupancy)::int  AS is_over_maximum,
    (dy.census_date >= w.test_start_date)::int                   AS is_test_period
FROM daily dy
CROSS JOIN mart.network_capacity nc
CROSS JOIN mart.analysis_window w;

ALTER TABLE mart.fact_daily_occupancy ADD PRIMARY KEY (census_date);
ALTER TABLE mart.fact_daily_occupancy ADD FOREIGN KEY (census_date) REFERENCES mart.dim_date (date);

-- Check 1: the headline numbers Power BI must reproduce (2017 to 2025)
SELECT
    COUNT(*)                                                          AS episodes,
    SUM(is_index_eligible)                                            AS index_episodes,
    SUM(is_readmitted_30d)                                            AS unplanned_readmissions,
    ROUND(100.0 * SUM(is_readmitted_30d) / NULLIF(SUM(is_index_eligible), 0), 2) AS readmission_rate_pct,
    SUM(died_in_hospital)                                             AS in_hospital_deaths,
    ROUND(100.0 * SUM(died_in_hospital) / COUNT(*), 2)                AS in_hospital_mortality_pct,
    ROUND(AVG(los_days), 2)                                           AS avg_los_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY los_days)             AS median_los_days,
    ROUND(SUM(total_cost) / 1e6, 2)                                   AS total_cost_millions,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_cost))::numeric, 2) AS median_cost
FROM mart.fact_episode;

-- Check 2: census in the window
SELECT
    SUM(patients_in_bed)                                              AS bed_days,
    ROUND(SUM(patients_in_bed)::numeric / (SELECT COUNT(*) FROM mart.dim_date), 2) AS avg_daily_census,
    (SELECT MAX(n) FROM (SELECT SUM(patients_in_bed) AS n
                         FROM mart.fact_daily_census GROUP BY census_date) x) AS peak_daily_census
FROM mart.fact_daily_census;

-- Check 3: episodes and readmissions per year (every year should be present)
SELECT
    EXTRACT(YEAR FROM admit_date)::int                                AS year,
    COUNT(*)                                                          AS episodes,
    SUM(is_readmitted_30d)                                            AS unplanned_readmissions,
    ROUND(100.0 * SUM(is_readmitted_30d) / NULLIF(SUM(is_index_eligible), 0), 2) AS readmission_rate_pct,
    ROUND(AVG(los_days), 2)                                           AS avg_los_days
FROM mart.fact_episode
GROUP BY 1
ORDER BY 1;

-- Check 4: network occupancy, full window vs test period (2023 to 2025)
SELECT
    CASE WHEN is_test_period = 1 THEN '2023-2025 (test period)'
         ELSE '2017-2022' END                                         AS period,
    MAX(beds)                                                         AS beds,
    COUNT(*)                                                          AS days,
    ROUND(100 * AVG(occupancy_rate), 1)                               AS avg_occupancy_pct,
    SUM(is_over_safe_level)                                           AS days_over_85,
    SUM(is_over_maximum)                                              AS days_over_92,
    ROUND(100 * MAX(occupancy_rate), 1)                               AS max_occupancy_pct
FROM mart.fact_daily_occupancy
GROUP BY 1
ORDER BY 1;

-- Check 5: network occupancy by year
SELECT
    EXTRACT(YEAR FROM census_date)::int                               AS year,
    ROUND(100 * AVG(occupancy_rate), 1)                               AS avg_occupancy_pct,
    SUM(is_over_safe_level)                                           AS days_over_85,
    SUM(is_over_maximum)                                              AS days_over_92,
    ROUND(100 * MAX(occupancy_rate), 1)                               AS max_occupancy_pct
FROM mart.fact_daily_occupancy
GROUP BY 1
ORDER BY 1;
