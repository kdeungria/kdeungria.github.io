"""
01_generate.py
Healthcare Analytics Project - Stage 2: Generate synthetic patient data with Synthea.

What this script does:
  1. Checks that Java 17+ is installed
  2. Uses the Synthea jar in tools/synthea/ (downloads it only if missing)
  3. Runs Synthea with a fixed seed so results are reproducible
  4. Exports only the 6 CSV files the pipeline uses, into data/synthea_csv/
  5. Prints a summary of every CSV and a sanity check on inpatient stays

Run from the project root folder:
    python python/01_generate.py
"""

import csv
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Settings - change these if you want a different dataset
# ---------------------------------------------------------------------------
SEED = 2026              # same seed = same dataset every time
POPULATION = 100000      # living patients to simulate (deceased ones are added on top)
STATE = "Massachusetts"  # Synthea's default demographics
JAVA_MEMORY = "4g"       # memory for Java; lower to "2g" if your laptop has 8GB RAM or less

# Only the CSVs the pipeline loads. Skipping the other 12 files (claims, observations,
# procedures, ...) cuts the output from about 75 GB to about 3 GB at 100,000 patients.
CSV_FILES = ["patients.csv", "encounters.csv", "conditions.csv",
             "organizations.csv", "providers.csv", "payers.csv"]

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent   # healthcare-analytics/
TOOLS_DIR = PROJECT_ROOT / "tools" / "synthea"            # jar lives in tools/synthea/
JAR_PATH = TOOLS_DIR / "synthea-with-dependencies.jar"
OUTPUT_DIR = PROJECT_ROOT / "data" / "synthea_output"    # Synthea writes here
CSV_DIR = OUTPUT_DIR / "csv"                             # CSVs land here
FINAL_CSV_DIR = PROJECT_ROOT / "data" / "synthea_csv"    # clean copy we load into SQL

JAR_URL = ("https://github.com/synthetichealth/synthea/releases/download/"
           "master-branch-latest/synthea-with-dependencies.jar")


def check_java():
    """Stop early with a clear message if Java 17+ is missing."""
    if shutil.which("java") is None:
        sys.exit("Java not found. Install JDK 17 or 25 (e.g. Eclipse Temurin), "
                 "reopen your terminal, then run this script again.")
    result = subprocess.run(["java", "-version"], capture_output=True, text=True)
    version_text = result.stderr or result.stdout
    match = re.search(r'version "(\d+)', version_text)
    major = int(match.group(1)) if match else 0
    if major < 17:
        sys.exit(f"Java {major} found, but Synthea needs Java 17 or newer.")
    print(f"[ok] Java {major} detected")


def get_synthea_jar():
    """Download the Synthea jar once; reuse it afterwards."""
    TOOLS_DIR.mkdir(parents=True, exist_ok=True)
    if JAR_PATH.exists():
        print(f"[ok] Synthea jar already present: {JAR_PATH.name}")
        return
    print("[..] Downloading Synthea jar (~150 MB, one time only)...")
    try:
        urllib.request.urlretrieve(JAR_URL, JAR_PATH)
    except Exception as err:
        sys.exit(f"Download failed ({err}).\nDownload it manually from:\n  {JAR_URL}\n"
                 f"and save it as:\n  {JAR_PATH}")
    print("[ok] Download complete")


def run_synthea():
    """Run Synthea with CSV export on and all FHIR exports off."""
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)  # start clean so old runs don't mix in

    cmd = [
        "java", f"-Xmx{JAVA_MEMORY}", "-jar", str(JAR_PATH),
        "-s", str(SEED),
        "-p", str(POPULATION),
        f"--exporter.baseDirectory={OUTPUT_DIR.as_posix()}/",
        "--exporter.csv.export=true",
        "--exporter.fhir.export=false",
        "--exporter.hospital.fhir.export=false",
        "--exporter.practitioner.fhir.export=false",
        f"--exporter.csv.included_files={','.join(CSV_FILES)}",
        STATE,
    ]
    print(f"[..] Running Synthea: seed={SEED}, population={POPULATION}, state={STATE}")
    print("     This can take 4-10 hours for 100,000 patients (best run overnight).\n"
          "     Progress prints below.\n")
    subprocess.run(cmd, check=True)
    print("\n[ok] Synthea finished")


def copy_csvs():
    """Move the CSVs into data/synthea_csv/ for the loading step."""
    if not CSV_DIR.exists():
        sys.exit(f"No CSV folder found at {CSV_DIR}. Check the Synthea output above for errors.")
    FINAL_CSV_DIR.mkdir(parents=True, exist_ok=True)
    for old in FINAL_CSV_DIR.glob("*.csv"):
        old.unlink()
    for f in CSV_DIR.glob("*.csv"):
        shutil.move(str(f), FINAL_CSV_DIR / f.name)   # move, not copy: avoids a second ~3 GB copy
    shutil.rmtree(OUTPUT_DIR, ignore_errors=True)       # remove Synthea's temporary output folder
    print(f"[ok] CSVs moved to {FINAL_CSV_DIR}")


def summarize():
    """Print row counts per file and check there are enough inpatient stays."""
    print("\n=== CSV summary ===")
    for f in sorted(FINAL_CSV_DIR.glob("*.csv")):
        with open(f, newline="", encoding="utf-8") as fh:
            rows = sum(1 for _ in fh) - 1  # minus header
        print(f"  {f.name:<28} {rows:>12,} rows")

    encounters = FINAL_CSV_DIR / "encounters.csv"
    if not encounters.exists():
        return
    counts = {}
    with open(encounters, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            cls = row.get("ENCOUNTERCLASS", "unknown")
            counts[cls] = counts.get(cls, 0) + 1

    print("\n=== Encounters by type ===")
    for cls, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {cls:<15} {n:>10,}")

    inpatient = counts.get("inpatient", 0)
    print("\n=== Sanity check ===")
    if inpatient >= 20000:
        print(f"  [ok] {inpatient:,} inpatient stays - enough for readmission analysis")
    else:
        print(f"  [warn] Only {inpatient:,} inpatient stays. Consider raising POPULATION "
              f"and running again.")


if __name__ == "__main__":
    check_java()
    get_synthea_jar()
    run_synthea()
    copy_csvs()
    summarize()
