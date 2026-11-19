-- =====================================================================
-- Stage 0 - Setup
-- Run this while connected to the hospital_analytics database.
-- (Create the database first in pgAdmin: right-click Databases > Create > Database...
--  name it hospital_analytics)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS raw;      -- CSVs loaded exactly as-is
CREATE SCHEMA IF NOT EXISTS staging;  -- cleaned, typed, filtered
CREATE SCHEMA IF NOT EXISTS mart;     -- star schema for Power BI

-- Check
SELECT schema_name
FROM information_schema.schemata
WHERE schema_name IN ('raw', 'staging', 'mart')
ORDER BY schema_name;
