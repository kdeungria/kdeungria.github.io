"""
02_load_raw.py
Healthcare Analytics Project - Stage 3: load ALL Synthea CSVs into PostgreSQL (raw schema).

What this script does:
  1. Creates the hospital_analytics database and the raw/staging/mart schemas if missing
  2. SCANS the database first: tables already loaded with the correct row count are skipped
  3. Loads the remaining CSVs into raw.<filename> using PostgreSQL COPY
       - column names converted to lowercase
       - every column stored as TEXT (types are fixed later in the staging layer)
       - smallest files first, the giant files last
  4. If a table FAILS, it is rolled back and the script CONTINUES with the next table
  5. Prints a summary, writes a load log, and runs the golden-number checks

Resume behaviour:
  Just run the script again after fixing a problem (e.g. freeing disk space).
  It picks up where it left off and only loads what is missing or incomplete.

Run (from the project root or the python folder):
    python python/02_load_raw.py                                   # resume / load missing tables
    python python/02_load_raw.py --only claims_transactions        # (re)load specific tables
    python python/02_load_raw.py --skip observations               # leave tables out
    python python/02_load_raw.py --force                           # reload everything from scratch
"""

import argparse
import csv
import json
import re
import sys
import time
from datetime import datetime

import psycopg2
from psycopg2 import sql

from config import DB, PATHS

CSV_DIR = PATHS["csv"]
LOG_DIR = PATHS["logs"]
STATE_FILE = LOG_DIR / "load_state.json"   # remembers which tables loaded successfully
SCHEMAS = ["raw", "staging", "mart"]

# Golden numbers from the generation run (seed 2026, population 5000)
GOLDEN = {"patients": 114513, "inpatient_stays": 107239}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def clean_name(name):
    """PATIENT -> patient, 'Some Column' -> some_column."""
    name = re.sub(r"[^0-9a-zA-Z_]+", "_", name.strip()).strip("_").lower()
    return name or "col"


def read_header(path):
    with open(path, newline="", encoding="utf-8") as fh:
        header = next(csv.reader(fh))
    cols, seen = [], set()
    for h in header:
        c = clean_name(h)
        while c in seen:
            c += "_dup"
        seen.add(c)
        cols.append(c)
    return cols


def count_csv_rows(path):
    """Count data rows with a real CSV parser (handles line breaks inside quoted fields)."""
    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.reader(fh)
        next(reader, None)
        return sum(1 for _ in reader)


def file_signature(path):
    st = path.stat()
    return {"size": st.st_size, "mtime": int(st.st_mtime)}


def load_state():
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(state):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
def connect(dbname):
    try:
        return psycopg2.connect(host=DB["host"], port=DB["port"], user=DB["user"],
                                password=DB["password"], dbname=dbname)
    except psycopg2.OperationalError as err:
        sys.exit(f"[error] Could not connect to PostgreSQL ({dbname}).\n{err}\n"
                 "Check that PostgreSQL is running and the password in .env is correct.")


def ensure_database():
    conn = connect("postgres")
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (DB["name"],))
        if cur.fetchone():
            print(f"[ok] Database '{DB['name']}' already exists")
        else:
            cur.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(DB["name"])))
            print(f"[ok] Database '{DB['name']}' created")
    conn.close()


def ensure_schemas(conn):
    with conn.cursor() as cur:
        for schema in SCHEMAS:
            cur.execute(sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(sql.Identifier(schema)))
    conn.commit()
    print(f"[ok] Schemas ready: {', '.join(SCHEMAS)}")


def table_row_count(conn, table):
    """Row count of raw.<table>, or None if the table doesn't exist."""
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass(%s)", (f"raw.{table}",))
        if cur.fetchone()[0] is None:
            return None
        cur.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(sql.Identifier("raw", table)))
        return cur.fetchone()[0]


def load_table(conn, path, table):
    """Drop, create and COPY one table inside a single transaction. Returns (cols, rows)."""
    cols = read_header(path)
    target = sql.Identifier("raw", table)
    with conn.cursor() as cur:
        cur.execute(sql.SQL("DROP TABLE IF EXISTS {}").format(target))
        cur.execute(sql.SQL("CREATE TABLE {} ({})").format(
            target,
            sql.SQL(", ").join(sql.SQL("{} TEXT").format(sql.Identifier(c)) for c in cols)))
        copy_stmt = sql.SQL("COPY {} ({}) FROM STDIN WITH (FORMAT csv, HEADER true)").format(
            target, sql.SQL(", ").join(sql.Identifier(c) for c in cols))
        with open(path, newline="", encoding="utf-8") as fh:
            cur.copy_expert(copy_stmt.as_string(conn), fh)
        cur.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(target))
        rows = cur.fetchone()[0]
    conn.commit()
    return len(cols), rows


# ---------------------------------------------------------------------------
# Scan: decide what needs loading
# ---------------------------------------------------------------------------
def already_loaded(conn, path, table, state):
    """True if raw.<table> exists and is complete. Uses the saved state when possible
    (fast); otherwise counts the CSV once and records the result."""
    db_rows = table_row_count(conn, table)
    if db_rows is None:
        return False, "not in database"

    sig = file_signature(path)
    saved = state.get(table)
    if saved and saved.get("size") == sig["size"] and saved.get("mtime") == sig["mtime"]:
        if saved.get("rows") == db_rows:
            return True, f"{db_rows:,} rows"
        return False, f"incomplete ({db_rows:,} of {saved['rows']:,} rows)"

    # No saved record (e.g. loaded by an older version of this script): verify by counting
    csv_rows = count_csv_rows(path)
    if csv_rows == db_rows:
        state[table] = {**sig, "rows": csv_rows}
        return True, f"{db_rows:,} rows (verified)"
    return False, f"incomplete ({db_rows:,} of {csv_rows:,} rows)"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def parse_args():
    ap = argparse.ArgumentParser(description="Load Synthea CSVs into the raw schema.")
    ap.add_argument("--only", nargs="+", metavar="TABLE", help="load only these tables")
    ap.add_argument("--skip", nargs="+", metavar="TABLE", default=[], help="skip these tables")
    ap.add_argument("--force", action="store_true",
                    help="reload tables even if they are already loaded")
    return ap.parse_args()


def main():
    args = parse_args()
    files = sorted(CSV_DIR.glob("*.csv"), key=lambda p: p.stat().st_size)  # small first
    if not files:
        sys.exit(f"[error] No CSV files found in {CSV_DIR}. Run 01_generate.py first.")
    if args.only:
        wanted = {clean_name(t.removesuffix(".csv")) for t in args.only}
        files = [f for f in files if clean_name(f.stem) in wanted]
    skip = {clean_name(t.removesuffix(".csv")) for t in args.skip}
    files = [f for f in files if clean_name(f.stem) not in skip]
    if not files:
        sys.exit("[error] No matching tables. Check the names after --only / --skip.")

    ensure_database()
    conn = connect(DB["name"])
    ensure_schemas(conn)
    state = load_state()

    # ---- Scan --------------------------------------------------------------
    print("\n=== Scanning database ===")
    to_load = []
    for f in files:
        table = clean_name(f.stem)
        if args.force or args.only:
            reason = "forced" if args.force else "requested with --only"
            done = False
        else:
            done, reason = already_loaded(conn, f, table, state)
        print(f"  {f.name:<28} {'[done]' if done else '[todo]'}  {reason}")
        if not done:
            to_load.append(f)
    save_state(state)

    # ---- Load --------------------------------------------------------------
    results = []
    if not to_load:
        print("\n[ok] All tables are already loaded. Nothing to do.")
    else:
        mb = sum(f.stat().st_size for f in to_load) / 1_048_576
        print(f"\n=== Loading {len(to_load)} table(s), {mb:,.0f} MB ===")
        start_all = time.time()
        for f in to_load:
            table = clean_name(f.stem)
            t0 = time.time()
            print(f"  {f.name:<28}", end="", flush=True)
            try:
                ncols, db_rows = load_table(conn, f, table)
            except Exception as err:
                conn.rollback()
                msg = str(err).strip().splitlines()[0]
                print(f" FAILED  ({msg})")
                if "No space left" in str(err):
                    print("        [hint] Disk is full - free up space, then re-run the script.")
                state.pop(table, None)
                save_state(state)
                results.append((f.name, table, "", "", "", "FAILED", round(time.time() - t0, 1), msg))
                continue   # keep going with the next table

            csv_rows = count_csv_rows(f)
            status = "ok" if csv_rows == db_rows else "MISMATCH"
            secs = time.time() - t0
            print(f"{db_rows:>12,} rows  {ncols:>3} cols  {secs:>6.1f}s  [{status}]")
            if status == "ok":
                state[table] = {**file_signature(f), "rows": csv_rows}
            else:
                state.pop(table, None)
            save_state(state)
            results.append((f.name, table, csv_rows, db_rows, ncols, status, round(secs, 1), ""))
        print(f"\n  Finished in {(time.time() - start_all) / 60:.1f} min")

    # ---- Final status of every table --------------------------------------
    all_files = sorted(CSV_DIR.glob("*.csv"), key=lambda p: p.stat().st_size)
    complete = [f for f in all_files if clean_name(f.stem) in state]
    missing = [f.name for f in all_files if clean_name(f.stem) not in state]

    # ---- Golden numbers ----------------------------------------------------
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM raw.patients")
            patients = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM raw.encounters WHERE encounterclass = 'inpatient'")
            inpatient = cur.fetchone()[0]
    except psycopg2.Error:
        conn.rollback()
        patients = inpatient = None
    conn.close()

    # ---- Log ---------------------------------------------------------------
    if results:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        log_path = LOG_DIR / f"load_log_{datetime.now():%Y%m%d_%H%M%S}.csv"
        with open(log_path, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["csv_file", "table", "csv_rows", "db_rows", "columns",
                        "status", "seconds", "error"])
            w.writerows(results)
        print(f"  Log saved to: {log_path}")

    print("\n=== Summary ===")
    print(f"  Tables complete : {len(complete)} of {len(all_files)}")
    if missing:
        print(f"  Still to load   : {', '.join(missing)}")
        print("  -> Fix the issue shown above and run the script again; it will resume.")

    print("\n=== Golden-number checks ===")
    if patients is None:
        print("  [skip] patients/encounters not loaded yet")
    else:
        for label, actual, expected in [("Patients", patients, GOLDEN["patients"]),
                                        ("Inpatient stays", inpatient, GOLDEN["inpatient_stays"])]:
            mark = "ok" if actual == expected else "CHECK"
            print(f"  [{mark}] {label:<16} {actual:>8,}  (expected {expected:,})")


if __name__ == "__main__":
    main()
