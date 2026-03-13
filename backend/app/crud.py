from datetime import datetime, timezone
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from .models import Word, Encounter, Page, SourceType
from .services.cedict import lookup_cedict, lookup_pinyin, format_definitions
from .services.priority import compute_priority


def is_cjk(text: str) -> bool:
    """Return True if all non-whitespace characters are CJK."""
    stripped = text.strip()
    if not stripped:
        return False
    return all(
        "\u4e00" <= ch <= "\u9fff"
        or "\u3400" <= ch <= "\u4dbf"  # CJK Extension A
        or "\uf900" <= ch <= "\ufaff"  # CJK Compatibility
        for ch in stripped
        if not ch.isspace()
    )


async def create_page(
    db: AsyncSession,
    url: str,
    title: str | None,
    page_purpose: str | None,
) -> Page:
    page = Page(
        url=url,
        title=title,
        page_purpose=page_purpose,
        captured_at=datetime.now(timezone.utc),
    )
    db.add(page)
    await db.flush()
    return page


async def upsert_word(
    db: AsyncSession,
    word_text: str,
    source_type: str,
    source_url: str | None,
    context_sentence: str | None,
) -> tuple[Word, bool]:
    """
    Insert or update a word in the corpus.
    Returns (word, is_new).
    """
    result = await db.execute(
        select(Word).where(Word.traditional == word_text).with_for_update()
    )
    word = result.scalar_one_or_none()
    is_new = word is None

    if is_new:
        cedict_entry = await lookup_cedict(db, word_text)
        pinyin = await lookup_pinyin(db, word_text)
        now = datetime.now(timezone.utc)
        word = Word(
            traditional=word_text,
            pinyin=pinyin,
            definition=format_definitions(cedict_entry) if cedict_entry else None,
            encounter_count=1,
            source_diversity_count=1,
            familiarity_score=0,
            ease_factor=2.5,
            srs_interval_days=1,
            created_at=now,
            updated_at=now,
        )
        db.add(word)
        await db.flush()
    else:
        word.encounter_count += 1

        # Check if this source_type has been seen before for this word
        seen = await db.execute(
            select(Encounter.id)
            .where(Encounter.word_id == word.id)
            .where(Encounter.source_type == source_type)
            .limit(1)
        )
        if seen.scalar_one_or_none() is None:
            word.source_diversity_count += 1

    # Log the encounter
    db.add(Encounter(
        word_id=word.id,
        source_type=source_type,
        source_url=source_url,
        context_sentence=context_sentence,
        encountered_at=datetime.now(timezone.utc),
    ))

    # Recompute priority score
    word.priority_score = compute_priority(word)

    return word, is_new


async def get_queue(db: AsyncSession, n: int = 20) -> list[tuple[Word, str | None]]:
    """Return top N words due for review, with their most recent context sentence."""
    from datetime import date
    from sqlalchemy import or_

    today = date.today()
    result = await db.execute(
        select(Word)
        .where(
            Word.familiarity_score == 1,
            or_(
                Word.next_review_date == None,
                Word.next_review_date <= today,
            ),
        )
        .order_by(Word.priority_score.desc())
        .limit(n)
    )
    words = result.scalars().all()

    items = []
    for word in words:
        enc_result = await db.execute(
            select(Encounter.context_sentence)
            .where(Encounter.word_id == word.id)
            .where(Encounter.context_sentence != None)
            .order_by(Encounter.encountered_at.desc())
            .limit(1)
        )
        context = enc_result.scalar_one_or_none()
        items.append((word, context))

    return items
