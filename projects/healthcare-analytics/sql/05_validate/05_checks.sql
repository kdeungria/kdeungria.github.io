-- =====================================================================
-- Stage 8 - Validate
-- Purpose : Prove the pipeline is internally consistent before Power BI uses it
-- Reads   : staging.*, mart.*
-- Creates : nothing permanent (a temporary results table)
--
-- Every check compares an EXPECTED value with an ACTUAL value. Four groups:
--   1. Reconciliation : totals agree between layers (nothing lost or duplicated)
--   2. Episode logic  : episodes never overlap, stays are mapped exactly once
--   3. Flag logic     : readmission and mortality flags never contradict each other
--   4. Integrity      : no missing keys or blank flags, no impossible values, complete calendar,
--                       network beds sized correctly
--
-- If ANY check fails, the last statement raises an error, so 03_run_sql.py stops
-- and reports it. The results table is printed before that, showing which failed.
-- =====================================================================

CREATE TEMP TABLE validation_results (
    check_group  text,
    check_name   text,
    expected     numeric,
    actual       numeric
) ON COMMIT DROP;

-- ---------------------------------------------------------------------
-- 1. Reconciliation between layers
-- ---------------------------------------------------------------------
INSERT INTO validation_results
SELECT '1. Reconciliation', 'Every stay mapped to exactly one episode',
       (SELECT COUNT(*) FROM staging.inpatient_stays),
       (SELECT COUNT(DISTINCT encounter_id) FROM staging.stay_episode_map)
UNION ALL
SELECT '1. Reconciliation', 'Stay cost total = episode cost total',
       (SELECT SUM(total_cost) FROM staging.inpatient_stays),
       (SELECT SUM(total_cost) FROM staging.episodes)
UNION ALL
SELECT '1. Reconciliation', 'Episode LOS days = census bed-days (all years)',
       (SELECT SUM(los_days) FROM staging.episodes),
       (SELECT SUM(patients_in_bed) FROM staging.daily_census)
UNION ALL
SELECT '1. Reconciliation', 'Mart episodes = staging episodes in window',
       (SELECT COUNT(*) FROM staging.episodes e, mart.analysis_window w
         WHERE e.admit_date BETWEEN w.start_date AND w.end_date),
       (SELECT COUNT(*) FROM mart.fact_episode)
UNION ALL
SELECT '1. Reconciliation', 'Mart cost = staging cost in window',
       (SELECT SUM(e.total_cost) FROM staging.episodes e, mart.analysis_window w
         WHERE e.admit_date BETWEEN w.start_date AND w.end_date),
       (SELECT SUM(total_cost) FROM mart.fact_episode)
UNION ALL
SELECT '1. Reconciliation', 'Mart census = staging census in window',
       (SELECT SUM(c.patients_in_bed) FROM staging.daily_census c, mart.analysis_window w
         WHERE c.census_date BETWEEN w.start_date AND w.end_date),
       (SELECT SUM(patients_in_bed) FROM mart.fact_daily_census)
UNION ALL
SELECT '1. Reconciliation', 'Occupancy patients = census patients in window',
       (SELECT SUM(patients_in_bed) FROM mart.fact_daily_census),
       (SELECT SUM(patients_in_bed) FROM mart.fact_daily_occupancy)
UNION ALL
SELECT '1. Reconciliation', 'Mart readmissions = staging readmissions in window',
       (SELECT COUNT(*) FROM staging.episode_readmissions r
          JOIN staging.episodes e ON e.episode_id = r.episode_id
          CROSS JOIN mart.analysis_window w
         WHERE r.is_readmitted_30d AND e.admit_date BETWEEN w.start_date AND w.end_date),
       (SELECT SUM(is_readmitted_30d) FROM mart.fact_episode);

-- ---------------------------------------------------------------------
-- 2. Episode logic
-- ---------------------------------------------------------------------
INSERT INTO validation_results
SELECT '2. Episode logic', 'No overlapping or same-day episodes for a patient',
       0,
       (SELECT COUNT(*) FROM (
            SELECT discharge_date,
                   LEAD(admit_date) OVER (PARTITION BY patient_id ORDER BY admit_ts, episode_id) AS next_admit
            FROM staging.episodes) x
         WHERE next_admit <= discharge_date)
UNION ALL
SELECT '2. Episode logic', 'Stays in episodes add up to all stays',
       (SELECT COUNT(*) FROM staging.inpatient_stays),
       (SELECT SUM(stays_in_episode) FROM staging.episodes)
UNION ALL
SELECT '2. Episode logic', 'Episodes with LOS under 1 day',
       0,
       (SELECT COUNT(*) FROM staging.episodes WHERE los_days < 1);

-- ---------------------------------------------------------------------
-- 3. Flag logic (mart.fact_episode)
-- ---------------------------------------------------------------------
INSERT INTO validation_results
SELECT '3. Flag logic', 'Readmissions that are not index episodes',
       0, (SELECT COUNT(*) FROM mart.fact_episode WHERE is_readmitted_30d = 1 AND is_index_eligible = 0)
UNION ALL
SELECT '3. Flag logic', 'Episodes flagged both unplanned and planned return',
       0, (SELECT COUNT(*) FROM mart.fact_episode WHERE is_readmitted_30d = 1 AND is_planned_return_30d = 1)
UNION ALL
SELECT '3. Flag logic', 'Readmissions outside the 1-30 day window',
       0, (SELECT COUNT(*) FROM mart.fact_episode
            WHERE is_readmitted_30d = 1 AND days_to_readmission NOT BETWEEN 1 AND 30)
UNION ALL
SELECT '3. Flag logic', 'In-hospital deaths counted as index episodes',
       0, (SELECT COUNT(*) FROM mart.fact_episode WHERE died_in_hospital = 1 AND is_index_eligible = 1)
UNION ALL
SELECT '3. Flag logic', 'Episodes flagged both in-hospital and 30-day death',
       0, (SELECT COUNT(*) FROM mart.fact_episode WHERE died_in_hospital = 1 AND died_within_30d = 1)
UNION ALL
SELECT '3. Flag logic', 'Planned-treatment returns counted as readmissions',
       0, (SELECT COUNT(*)
             FROM mart.fact_episode f
             JOIN staging.episode_readmissions r ON r.episode_id = f.episode_id
            WHERE f.is_readmitted_30d = 1 AND r.next_is_planned);

-- ---------------------------------------------------------------------
-- 4. Integrity
-- ---------------------------------------------------------------------
INSERT INTO validation_results
SELECT '4. Integrity', 'Fact rows with a missing key',
       0, (SELECT COUNT(*) FROM mart.fact_episode
            WHERE patient_id IS NULL OR organization_id IS NULL OR provider_id IS NULL
               OR payer_id IS NULL OR diagnosis_key IS NULL OR admit_date IS NULL)
UNION ALL
SELECT '4. Integrity', 'Fact rows admitted outside the window',
       0, (SELECT COUNT(*) FROM mart.fact_episode f, mart.analysis_window w
            WHERE f.admit_date NOT BETWEEN w.start_date AND w.end_date)
UNION ALL
SELECT '4. Integrity', 'Fact rows with a blank flag',
       0, (SELECT COUNT(*) FROM mart.fact_episode
            WHERE is_index_eligible IS NULL OR is_readmitted_30d IS NULL
               OR is_planned_return_30d IS NULL OR died_in_hospital IS NULL
               OR died_within_30d IS NULL OR is_planned_treatment IS NULL)
UNION ALL
SELECT '4. Integrity', 'Negative costs',
       0, (SELECT COUNT(*) FROM mart.fact_episode WHERE total_cost < 0 OR patient_paid < 0)
UNION ALL
SELECT '4. Integrity', 'Calendar has every day of the window',
       (SELECT end_date - start_date + 1 FROM mart.analysis_window),
       (SELECT COUNT(*) FROM mart.dim_date)
UNION ALL
SELECT '4. Integrity', 'Census rows with no patients',
       0, (SELECT COUNT(*) FROM mart.fact_daily_census WHERE patients_in_bed <= 0)
UNION ALL
SELECT '4. Integrity', 'Every episode year 2017-2025 is present',
       (SELECT EXTRACT(YEAR FROM end_date) - EXTRACT(YEAR FROM start_date) + 1 FROM mart.analysis_window),
       (SELECT COUNT(DISTINCT EXTRACT(YEAR FROM admit_date)) FROM mart.fact_episode)
UNION ALL
SELECT '4. Integrity', 'Occupancy rows = days in window',
       (SELECT COUNT(*) FROM mart.dim_date),
       (SELECT COUNT(*) FROM mart.fact_daily_occupancy)
UNION ALL
SELECT '4. Integrity', 'Days with missing occupancy',
       0, (SELECT COUNT(*) FROM mart.fact_daily_occupancy
            WHERE occupancy_rate IS NULL OR beds IS NULL OR beds < 1)
UNION ALL
SELECT '4. Integrity', 'Network sized above the target average occupancy',
       0, (SELECT (SUM(patients_in_bed)::numeric / (MAX(beds) * COUNT(*))
                   > (SELECT target_occupancy FROM mart.analysis_window))::int
             FROM mart.fact_daily_occupancy);

-- ---------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------
SELECT check_group,
       check_name,
       expected,
       actual,
       CASE WHEN expected IS NOT DISTINCT FROM actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM validation_results
ORDER BY check_group, check_name;

SELECT COUNT(*)                                                         AS checks,
       COUNT(*) FILTER (WHERE expected IS NOT DISTINCT FROM actual)     AS passed,
       COUNT(*) FILTER (WHERE expected IS DISTINCT FROM actual)         AS failed
FROM validation_results;

-- Stop the pipeline if anything failed
DO $$
DECLARE
    n_failed int;
BEGIN
    SELECT COUNT(*) INTO n_failed
    FROM validation_results
    WHERE expected IS DISTINCT FROM actual;

    IF n_failed > 0 THEN
        RAISE EXCEPTION '% validation check(s) failed. See the results table above.', n_failed;
    END IF;
END $$;
