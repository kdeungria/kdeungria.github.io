-- =====================================================================
-- Stage 6 - Business logic
-- Purpose : Patients in a bed per hospital per day (the census)
-- Reads   : staging.episodes
-- Creates : staging.daily_census (one row per hospital per day with patients)
--
-- Rules (decided after the exploratory data analysis):
--   * Capacity is measured with census metrics, NOT bed occupancy %, because
--     Synthea has no bed counts, so any assumed bed count would not be
--     meaningful
--   * Midnight census: a patient counts on each day from admission up to the day
--     before discharge (minimum one day). So bed-days in this table = episode LOS,
--     which is checked below
--   * Episodes (not stays) are used, so a patient in overlapping stays is not
--     counted twice on the same day
--   * Only days with at least one patient are stored. Average daily census is
--     calculated later as bed-days / calendar days in the period, so the empty days
--     do not need to be stored
--
-- Technique: generate_series() turns each episode into one row per day in bed
--
-- Note on time zones:
--   generate_series(date, date, interval) silently returns timestamps WITH time
--   zone in the session time zone. Where that zone had a historical clock change
--   at midnight (for example Asia/Kuala_Lumpur on 1942-02-16), a day can be
--   skipped. Both dates are cast to plain timestamp (no time zone) so clock
--   changes cannot skip or repeat a day
-- =====================================================================

DROP TABLE IF EXISTS staging.daily_census CASCADE;

CREATE TABLE staging.daily_census AS
SELECT
    d.day::date                         AS census_date,
    e.organization_id,
    COUNT(*)                            AS patients_in_bed
FROM staging.episodes e
CROSS JOIN LATERAL generate_series(
    e.admit_date::timestamp,
    GREATEST(e.discharge_date - 1, e.admit_date)::timestamp,
    INTERVAL '1 day'
) AS d(day)
GROUP BY d.day::date, e.organization_id;

ALTER TABLE staging.daily_census ADD PRIMARY KEY (census_date, organization_id);

-- Check 1: bed-days must equal total episode LOS
SELECT
    (SELECT SUM(patients_in_bed) FROM staging.daily_census) AS census_bed_days,
    (SELECT SUM(los_days)        FROM staging.episodes)     AS episode_los_days;

-- Check 2: network census in the analysis window (2017 to 2025)
WITH network AS (
    SELECT census_date, SUM(patients_in_bed) AS patients_in_bed
    FROM staging.daily_census
    WHERE census_date BETWEEN DATE '2017-01-01' AND DATE '2025-12-31'
    GROUP BY census_date
)
SELECT
    SUM(patients_in_bed)                                                AS bed_days,
    ROUND(SUM(patients_in_bed)::numeric
          / (DATE '2025-12-31' - DATE '2017-01-01' + 1), 2)             AS avg_daily_census,
    MAX(patients_in_bed)                                                AS peak_daily_census
FROM network;
