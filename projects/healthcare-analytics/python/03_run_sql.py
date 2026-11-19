"""
03_run_sql.py
Healthcare Analytics Project - runs the SQL pipeline (setup, staging, logic, mart, validate).

What this script does:
  1. Finds every .sql file under sql/, folder by folder in number order
     (00_setup -> 02_staging -> 03_logic -> 04_mart -> 05_validate)
  2. Skips the exploration folder (exploration lives in the notebook) and any file
     that has no SQL yet (only comments)
  3. Runs each file as ONE transaction: if any statement fails, that file is rolled
     back, the run stops, and the failing statement and error are shown
  4. Prints the result of every check query (SELECT) so you can see the numbers
  5. Runs the golden-number checks and saves a log in logs/

Run (from the project root or the python folder):
    python python/03_run_sql.py                     # run the whole SQL pipeline
    python python/03_run_sql.py --only 02_staging   # run one folder
    python python/03_run_sql.py --only 02b          # run one file (by name prefix)
    python python/03_run_sql.py --from 03_logic     # start from a folder or file
"""

import argparse
import sys
import time
from datetime import datetime

import pandas as pd
import psycopg2
import sqlparse

from config import DB, PATHS

SQL_DIR = PATHS["sql"]
LOG_DIR = PATHS["logs"]
SKIP_FOLDERS = {"01_explore"}   # exploration is done in the notebook
MAX_ROWS_SHOWN = 25

# Golden numbers: (label, table that must exist, query, expected value)
GOLDEN = [
    ("Staging patients", "staging.patients",
     "SELECT COUNT(*) FROM staging.patients", 114513),
    ("Staging inpatient stays", "staging.inpatient_stays",
     "SELECT COUNT(*) FROM staging.inpatient_stays", 107239),
    ("Episodes of care", "staging.episodes",
     "SELECT COUNT(*) FROM staging.episodes", 100794),
    ("Index episodes", "staging.episode_readmissions",
     "SELECT COUNT(*) FROM staging.episode_readmissions WHERE is_index_eligible", 99462),
    ("Unplanned readmissions", "staging.episode_readmissions",
     "SELECT COUNT(*) FROM staging.episode_readmissions WHERE is_readmitted_30d", 1269),
    ("In-hospital deaths", "staging.episode_mortality",
     "SELECT COUNT(*) FROM staging.episode_mortality WHERE died_in_hospital", 1020),
    ("Census bed-days", "staging.daily_census",
     "SELECT SUM(patients_in_bed) FROM staging.daily_census", 499308),
    ("Mart episodes 2017-2025", "mart.fact_episode",
     "SELECT COUNT(*) FROM mart.fact_episode", 37327),
    ("Mart index episodes", "mart.fact_episode",
     "SELECT SUM(is_index_eligible) FROM mart.fact_episode", 36872),
    ("Mart readmissions", "mart.fact_episode",
     "SELECT SUM(is_readmitted_30d) FROM mart.fact_episode", 639),
    ("Mart in-hospital deaths", "mart.fact_episode",
     "SELECT SUM(died_in_hospital) FROM mart.fact_episode", 455),
    ("Mart census bed-days", "mart.fact_daily_census",
     "SELECT SUM(patients_in_bed) FROM mart.fact_daily_census", 211777),
    ("Network beds", "mart.network_capacity",
     "SELECT beds FROM mart.network_capacity", 90),
    ("Test days over 85% occupancy", "mart.fact_daily_occupancy",
     "SELECT SUM(is_over_safe_level) FROM mart.fact_daily_occupancy WHERE is_test_period = 1", 49),
    ("Test days over 92% occupancy", "mart.fact_daily_occupancy",
     "SELECT SUM(is_over_maximum) FROM mart.fact_daily_occupancy WHERE is_test_period = 1", 7),
]

LOG_LINES = []


def out(text=""):
    """Print and keep a copy for the log file."""
    print(text)
    LOG_LINES.append(text)


def save_log():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    path = LOG_DIR / f"sql_run_{datetime.now():%Y%m%d_%H%M%S}.log"
    path.write_text("\n".join(LOG_LINES), encoding="utf-8")
    print(f"\nLog saved to: {path}")


# ---------------------------------------------------------------------------
# Finding and splitting the SQL
# ---------------------------------------------------------------------------
def discover():
    files = []
    for folder in sorted(p for p in SQL_DIR.iterdir() if p.is_dir()):
        if folder.name in SKIP_FOLDERS:
            continue
        files.extend(sorted(folder.glob("*.sql")))
    return files


def matches(path, token):
    """'02_staging' matches a folder, '02b' or '02b_stg_inpatient_stays' matches a file."""
    token = token.removesuffix(".sql")
    return path.parent.name.startswith(token) or path.stem.startswith(token)


def split_statements(sql_text):
    """Split a file into statements, ignoring chunks that are only comments."""
    statements = []
    for chunk in sqlparse.split(sql_text):
        code_only = sqlparse.format(chunk, strip_comments=True).strip().rstrip(";").strip()
        if code_only:
            statements.append(chunk.strip())
    return statements


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------
def show_result(columns, rows):
    df = pd.DataFrame(rows[:MAX_ROWS_SHOWN], columns=columns, dtype=object)
    df = df.where(df.notna(), "")        # show NULL as blank instead of NaN
    for line in df.to_string(index=False).splitlines():
        out("      " + line)
    if len(rows) > MAX_ROWS_SHOWN:
        out(f"      ... (only the first {MAX_ROWS_SHOWN} rows are shown)")
    out()


def run_file(conn, path):
    """Run every statement in one transaction. Returns (status, statements, error_info)."""
    statements = split_statements(path.read_text(encoding="utf-8"))
    if not statements:
        return "skipped", 0, None

    with conn.cursor() as cur:
        for i, stmt in enumerate(statements, 1):
            try:
                cur.execute(stmt)
            except psycopg2.Error as err:
                conn.rollback()
                return "failed", len(statements), (i, stmt, err)
            if cur.description:          # the statement returned rows: a check query
                columns = [d.name for d in cur.description]
                show_result(columns, cur.fetchmany(MAX_ROWS_SHOWN + 1))
    conn.commit()
    return "ok", len(statements), None


def report_failure(path, total, error_info):
    i, stmt, err = error_info
    out(f"    FAILED at statement {i} of {total}")
    out("")
    for line in str(err).strip().splitlines():
        out(f"    {line}")
    out("")
    out("    Failing statement:")
    lines = sqlparse.format(stmt, strip_comments=True).strip().splitlines()
    for line in lines[:15]:
        out(f"      {line}")
    if len(lines) > 15:
        out("      ...")
    out("")
    out("Stopped. Files before this one were saved; this file was rolled back.")
    out("Fix the SQL, then continue from here with:")
    out(f"    python python/03_run_sql.py --from {path.stem.split('_')[0]}")


def golden_checks(conn):
    out("\n=== Golden-number checks ===")
    with conn.cursor() as cur:
        for label, table, query, expected in GOLDEN:
            cur.execute("SELECT to_regclass(%s)", (table,))
            if cur.fetchone()[0] is None:
                out(f"  [skip]  {label:<26} (not built yet)")
                continue
            cur.execute(query)
            actual = cur.fetchone()[0]
            mark = "ok" if actual == expected else "CHECK"
            out(f"  [{mark}] {' ' if mark == 'ok' else ''}{label:<26} {actual:>8,}  (expected {expected:,})")
    conn.rollback()


def parse_args():
    ap = argparse.ArgumentParser(description="Run the project's SQL files in order.")
    ap.add_argument("--only", nargs="+", metavar="NAME",
                    help="run only these folders or files (name prefixes, e.g. 02_staging or 02b)")
    ap.add_argument("--from", dest="start", metavar="NAME",
                    help="start from this folder or file and run everything after it")
    return ap.parse_args()


def main():
    args = parse_args()
    files = discover()
    if not files:
        sys.exit(f"[error] No .sql files found under {SQL_DIR}")
    if args.start:
        idx = next((i for i, f in enumerate(files) if matches(f, args.start)), None)
        if idx is None:
            sys.exit(f"[error] Nothing matches --from {args.start}")
        files = files[idx:]
    if args.only:
        files = [f for f in files if any(matches(f, t) for t in args.only)]
        if not files:
            sys.exit(f"[error] Nothing matches --only {' '.join(args.only)}")

    try:
        conn = psycopg2.connect(host=DB["host"], port=DB["port"], user=DB["user"],
                                password=DB["password"], dbname=DB["name"])
    except psycopg2.OperationalError as err:
        sys.exit(f"[error] Could not connect to '{DB['name']}'.\n{err}\n"
                 "Check that PostgreSQL is running, the .env password is correct, "
                 "and 02_load_raw.py has been run.")
    with conn.cursor() as cur:
        cur.execute("SET client_min_messages = warning")   # hide 'table does not exist, skipping'
    conn.commit()

    out(f"=== Running SQL pipeline: {len(files)} file(s) ===")
    results, folder, t_all = [], None, time.time()
    for f in files:
        if f.parent.name != folder:
            folder = f.parent.name
            out(f"\n[{folder}]")
        out(f"  > {f.name}")
        t0 = time.time()
        status, n, error_info = run_file(conn, f)
        secs = time.time() - t0
        results.append((f, status))

        if status == "failed":
            report_failure(f, n, error_info)
            conn.close()
            save_log()
            sys.exit(1)
        if status == "skipped":
            out("    skipped (no SQL yet)")
        else:
            out(f"    ok: {n} statement(s), {secs:.1f}s")

    golden_checks(conn)
    conn.close()

    ok = sum(1 for _, s in results if s == "ok")
    skipped = sum(1 for _, s in results if s == "skipped")
    out("\n=== Summary ===")
    out(f"  Files run     : {ok}")
    out(f"  Files skipped : {skipped} (no SQL yet)")
    out(f"  Total time    : {time.time() - t_all:.1f}s")
    save_log()


if __name__ == "__main__":
    main()
