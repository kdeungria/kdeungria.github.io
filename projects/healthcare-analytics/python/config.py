"""
config.py - shared settings for every Python script in the project.
Import it like:   from config import PATHS, get_engine
"""

import os
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import create_engine

PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env")

PATHS = {
    "root": PROJECT_ROOT,
    "tools": PROJECT_ROOT / "tools" / "synthea",
    "synthea_output": PROJECT_ROOT / "data" / "synthea_output",
    "csv": PROJECT_ROOT / "data" / "synthea_csv",
    "sql": PROJECT_ROOT / "sql",
    "logs": PROJECT_ROOT / "logs",
}

DB = {
    "host": os.getenv("DB_HOST", "localhost"),
    "port": os.getenv("DB_PORT", "5432"),
    "name": os.getenv("DB_NAME", "hospital_analytics"),
    "user": os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
}


def get_engine():
    """Return a SQLAlchemy engine connected to the project database."""
    url = (f"postgresql+psycopg2://{DB['user']}:{DB['password']}"
           f"@{DB['host']}:{DB['port']}/{DB['name']}")
    return create_engine(url)


if __name__ == "__main__":
    # Quick connection test:  python python/config.py
    from sqlalchemy import text
    with get_engine().connect() as conn:
        version = conn.execute(text("SELECT version()")).scalar()
    print("[ok] Connected to PostgreSQL:")
    print("    ", version)
