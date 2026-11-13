"""Run every sql/NN_*.sql file and save each "-- name: X" query to outputs/tables/X.csv.

Usage:  python src/run_sql.py            # run all
        python src/run_sql.py 02         # run only files starting with 02
"""
import re
import sqlite3
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "data" / "olist.db"
OUT = ROOT / "outputs" / "tables"


def split_named_queries(sql_text: str) -> list[tuple[str, str]]:
    parts = re.split(r"^--\s*name:\s*(\w+)\s*$", sql_text, flags=re.M)
    # parts = [preamble, name1, body1, name2, body2, ...]
    return [(parts[i], parts[i + 1].strip().rstrip(";")) for i in range(1, len(parts), 2)]


def main(prefix: str = "") -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB)
    for f in sorted((ROOT / "sql").glob("[0-9][0-9]_*.sql")):
        if f.name.startswith("00_") or not f.name.startswith(prefix):
            continue
        print(f"\n### {f.name}")
        for name, query in split_named_queries(f.read_text()):
            df = pd.read_sql_query(query, con)
            df.to_csv(OUT / f"{name}.csv", index=False)
            print(f"\n-- {name}  ({len(df)} rows)")
            print(df.head(12).to_string(index=False))
    con.close()


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "")
