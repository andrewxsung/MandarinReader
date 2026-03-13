from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, distinct
from ..database import get_db
from ..models import Word, Encounter, Page
from ..services.cedict import lookup_cedict, format_definitions
from ..schemas import WordStats, WordLookup, WordQueueItem

router = APIRouter()


@router.get("/words", response_model=list[WordStats])
async def list_words(
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Word)
        .order_by(Word.priority_score.desc())
        .limit(limit)
        .offset(offset)
    )
    words = result.scalars().all()
    return [WordStats.model_validate(w) for w in words]


@router.get("/recent", response_model=list[WordQueueItem])
async def get_recent(db: AsyncSession = Depends(get_db)):
    """Top 10 words by priority from the last 2 captured pages."""
    # Get the 2 most recent pages
    pages_result = await db.execute(
        select(Page).order_by(Page.captured_at.desc()).limit(2)
    )
    pages = pages_result.scalars().all()
    if not pages:
        return []

    urls = [p.url for p in pages if p.url]

    # Words that have an encounter from one of those page URLs
    result = await db.execute(
        select(Word)
        .join(Encounter, Encounter.word_id == Word.id)
        .where(Encounter.source_url.in_(urls))
        .where(Word.familiarity_score >= 0)
        .distinct()
        .order_by(Word.priority_score.desc())
        .limit(10)
    )
    words = result.scalars().all()
    return [
        WordQueueItem(
            id=w.id, traditional=w.traditional, pinyin=w.pinyin,
            definition=w.definition, priority_score=float(w.priority_score),
            encounter_count=w.encounter_count, context_sentence=None,
        )
        for w in words
    ]


@router.get("/word/{word}", response_model=WordLookup)
async def get_word(word: str, db: AsyncSession = Depends(get_db)):
    # Check corpus first
    corpus_result = await db.execute(select(Word).where(Word.traditional == word))
    corpus_word = corpus_result.scalar_one_or_none()

    if corpus_word:
        return WordLookup(
            traditional=corpus_word.traditional,
            pinyin=corpus_word.pinyin,
            definition=corpus_word.definition,
            in_corpus=True,
            familiarity_score=corpus_word.familiarity_score,
            encounter_count=corpus_word.encounter_count,
        )

    # Fall back to CC-CEDICT lookup
    cedict_entry = await lookup_cedict(db, word)
    if cedict_entry:
        return WordLookup(
            traditional=cedict_entry.traditional,
            pinyin=cedict_entry.pinyin,
            definition=format_definitions(cedict_entry),
            in_corpus=False,
            familiarity_score=None,
            encounter_count=None,
        )

    raise HTTPException(status_code=404, detail="Word not found in corpus or dictionary")
