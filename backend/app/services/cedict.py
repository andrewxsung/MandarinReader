import re
from pathlib import Path
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ..models import CedictEntry

CEDICT_LINE = re.compile(r'^(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+/(.+)/$')


def parse_cedict(filepath: str | Path) -> list[dict]:
    """Parse CC-CEDICT file and return list of entry dicts."""
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


async def lookup_cedict(db: AsyncSession, traditional: str) -> CedictEntry | None:
    """Return the first CEDICT entry matching the traditional form."""
    result = await db.execute(
        select(CedictEntry)
        .where(CedictEntry.traditional == traditional)
        .limit(1)
    )
    return result.scalar_one_or_none()


async def lookup_pinyin(db: AsyncSession, traditional: str) -> str | None:
    """
    Get pinyin for a word, falling back to character-by-character lookup
    if the whole word isn't in CEDICT (common for 3-4 char compounds).
    """
    entry = await lookup_cedict(db, traditional)
    if entry:
        return entry.pinyin

    # Fallback: look up each character individually and join
    if len(traditional) <= 1:
        return None

    parts = []
    for char in traditional:
        result = await db.execute(
            select(CedictEntry.pinyin)
            .where(CedictEntry.traditional == char)
            .limit(1)
        )
        char_pinyin = result.scalar_one_or_none()
        if char_pinyin is None:
            return None  # give up if any character is missing
        parts.append(char_pinyin)

    return " ".join(parts)


def format_definitions(entry: CedictEntry) -> str:
    """Join definitions array into a display string."""
    return " / ".join(entry.definitions[:5])  # cap at 5 definitions for display
