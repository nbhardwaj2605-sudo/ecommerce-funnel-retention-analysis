#!/usr/bin/env bash
# Rebuild the whole project from the raw CSVs in data/raw/
set -euo pipefail
cd "$(dirname "$0")"
python src/load_data.py        # CSV -> data/olist.db (+ views)
python src/run_sql.py          # sql/*.sql -> outputs/tables/*.csv
python src/make_charts.py      # -> outputs/figures/01-08
python src/model.py            # -> outputs/figures/09-11, model tables
python src/export_powerbi.py   # -> powerbi/data/*.csv
echo "Done."
