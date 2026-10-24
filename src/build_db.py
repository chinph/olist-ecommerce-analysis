"""Build data/olist.duckdb from the raw Kaggle CSVs by running sql/01_staging.sql.

    python src/build_db.py
"""
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
DB = ROOT / "data" / "olist.duckdb"


def main() -> None:
    missing = [f for f in ["olist_orders_dataset.csv", "olist_customers_dataset.csv"] if not (RAW / f).exists()]
    if missing:
        raise SystemExit(f"Missing {missing} in {RAW}. Download the dataset from Kaggle first (see README).")
    sql = (ROOT / "sql" / "01_staging.sql").read_text(encoding="utf-8").replace("{RAW}", RAW.as_posix())
    with duckdb.connect(str(DB)) as con:
        con.execute(sql)
        for (t,) in con.execute("SELECT table_name FROM information_schema.tables WHERE table_type = 'BASE TABLE' ORDER BY 1").fetchall():
            n = con.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
            print(f"  {t:<18} {n:>9,} rows")
    print(f"Built {DB.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
