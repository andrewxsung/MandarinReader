"""HSK 1 starter deck: every new account begins with these words in its queue.

The word list lives in app/data/hsk1.json: the 150 HSK 2.0 Level 1 words in
Traditional characters, with numbered pinyin and short definitions. It was
built from the MIT-licensed complete-hsk-vocabulary dataset
(github.com/drkameleon/complete-hsk-vocabulary), whose definitions come from
CC-CEDICT (CC BY-SA). Readings were picked for the HSK 1 sense (for example
那 nà, not the surname Nā) and Taiwan-standard characters (裡, 幾, 歲, 聽).

Seeded words have no encounters, so their priority is 0: anything the user
actually captures still outranks them in the queue.
"""
import json
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from ..models import Word

HSK1_PATH = Path(__file__).resolve().parent.parent / "data" / "hsk1.json"
HSK1_TIER = 1


@lru_cache(maxsize=1)
def load_hsk1() -> tuple[dict, ...]:
    with open(HSK1_PATH, encoding="utf-8") as f:
        return tuple(json.load(f)["words"])


async def seed_starter_deck(db: AsyncSession, user_id: int) -> int:
    """Add the HSK 1 words to a user's corpus. Returns how many rows were inserted.

    Idempotent: words the user already has are left untouched (ON CONFLICT DO NOTHING
    on the (user_id, traditional) unique key). Does not commit.
    """
    now = datetime.now(timezone.utc)
    rows = [
        {
            "user_id": user_id,
            "traditional": w["traditional"],
            "pinyin": w["pinyin"],
            "definition": w["definition"],
            "hsk_tier": HSK1_TIER,
            "familiarity_score": 0,
            "encounter_count": 0,
            "source_diversity_count": 0,
            "priority_score": 0,
            "ease_factor": 2.5,
            "srs_interval_days": 1,
            "created_at": now,
            "updated_at": now,
        }
        for w in load_hsk1()
    ]
    stmt = (
        insert(Word)
        .values(rows)
        .on_conflict_do_nothing(constraint="words_user_traditional_key")
        .returning(Word.id)
    )
    result = await db.execute(stmt)
    return len(result.scalars().all())
