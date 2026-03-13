#!/usr/bin/env python3
"""
One-time CC-CEDICT import script.
Run from the backend/ directory: python migrations/002_load_cedict.py

Download CC-CEDICT first:
  https://www.mdbg.net/chinese/dictionary?page=cc-cedict
  Gunzip the file and place it at: backend/data/cedict_ts.u8
"""

import asyncio
import re
import sys
from pathlib import Path

import asyncpg
from dotenv import load_dotenv
import os

load_dotenv()

CEDICT_PATH = Path(__file__).parent.parent / "data" / "cedict_ts.u8"
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://localhost/mandarinreader")
# asyncpg uses standard postgres:// URL (not the sqlalchemy asyncpg+postgresql:// form)
ASYNCPG_URL = DATABASE_URL.replace("postgresql+asyncpg://", "postgresql://")

CEDICT_LINE = re.compile(r'^(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+/(.+)/$')
BATCH_SIZE = 1000


def parse_cedict(filepath: Path) -> list[dict]:
    entries = []
    with open(filepath, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = CEDICT_LINE.match(line)
            if not m:
                continue
            traditional, simplified, pinyin, defs_raw = m.groups()
            definitions = [d.strip() for d in defs_raw.split("/") if d.strip()]
            entries.append({
                "traditional": traditional,
                "simplified": simplified,
                "pinyin": pinyin,
                "definitions": definitions,
            })
    return entries


async def main():
    if not CEDICT_PATH.exists():
        print(f"ERROR: CC-CEDICT file not found at {CEDICT_PATH}")
        print("Download from https://www.mdbg.net/chinese/dictionary?page=cc-cedict")
        sys.exit(1)

    print(f"Parsing {CEDICT_PATH}...")
    entries = parse_cedict(CEDICT_PATH)
    print(f"Parsed {len(entries):,} entries")

    conn = await asyncpg.connect(ASYNCPG_URL)
    try:
        # Check if already loaded
        count = await conn.fetchval("SELECT COUNT(*) FROM cedict")
        if count > 0:
            print(f"cedict table already has {count:,} rows. Skipping import.")
            print("To reimport, run: TRUNCATE cedict; then rerun this script.")
            return

        print("Inserting into database in batches of 1000...")
        inserted = 0
        for i in range(0, len(entries), BATCH_SIZE):
            batch = entries[i : i + BATCH_SIZE]
            await conn.executemany(
                """
                INSERT INTO cedict (traditional, simplified, pinyin, definitions)
                VALUES ($1, $2, $3, $4)
                ON CONFLICT (traditional, pinyin) DO NOTHING
                """,
                [(e["traditional"], e["simplified"], e["pinyin"], e["definitions"]) for e in batch],
            )
            inserted += len(batch)
            print(f"  {inserted:,}/{len(entries):,}", end="\r")

        final_count = await conn.fetchval("SELECT COUNT(*) FROM cedict")
        print(f"\nDone. {final_count:,} rows in cedict table.")
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
