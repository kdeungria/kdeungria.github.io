# Troubleshooting Guide

Diagnose by checking row counts layer by layer: CSV -> raw -> staging -> mart -> Power BI.
The first layer where the count changes unexpectedly is where the problem is.

| Stage | Symptom | Likely cause | Fix |
|---|---|---|---|
| Setup | "not recognized as a command" | Java/Python not on PATH | Reopen terminal; reinstall with PATH option |
| Setup | "password authentication failed" | Wrong DB password in .env | Check .env against pgAdmin |
| Generate | OutOfMemoryError | Java memory too low/high | Change JAVA_MEMORY in 01_generate.py |
| Generate | Same seed, different numbers | New Synthea jar version | Keep the original jar in tools/ |
| Load | column "patient" does not exist | Uppercase CSV headers | Lowercase columns during load |
| Load | Script hangs / memory error | Very large tables | Load in chunks or skip unused tables |
| SQL | Counts or costs too high | Join fan-out | One row per stay before joining |
| SQL | Readmission rate > 20% | Transfers counted as readmissions | Apply same-day transfer rule |
| SQL | LOS off by one day | Time zone handling | Use timestamptz; one date rule |
| Power BI | "remote certificate is invalid" | SSL on local DB | Untick Encrypt connections |
| Power BI | Slicers don't change totals | Wrong relationships | One-to-many, dims to facts |
| Power BI | Number differs from SQL | DAX filter context | Reconcile against SQL golden number |

## Golden numbers (fill in once validated)
| Check | Value |
|---|---|
| Total patients | |
| Total inpatient stays | |
| Readmission rate | |
| ALOS | |
