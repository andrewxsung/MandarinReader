import json
import os
from datetime import date

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..models import Encounter, Word
from ..schemas import FreeStudyResponse, StudyPlanResponse, WordQueueItem

router = APIRouter()


async def _get_context(db: AsyncSession, word_id: int) -> str | None:
    result = await db.execute(
        select(Encounter.context_sentence)
        .where(Encounter.word_id == word_id)
        .where(Encounter.context_sentence != None)
        .order_by(Encounter.encountered_at.desc())
        .limit(1)
    )
    return result.scalar_one_or_none()


async def _word_to_queue_item(db: AsyncSession, w: Word) -> WordQueueItem:
    ctx = await _get_context(db, w.id)
    return WordQueueItem(
        id=w.id,
        traditional=w.traditional,
        pinyin=w.pinyin,
        definition=w.definition,
        priority_score=float(w.priority_score or 0),
        encounter_count=w.encounter_count,
        context_sentence=ctx,
    )


@router.get("/study/plan", response_model=StudyPlanResponse)
async def get_study_plan(db: AsyncSession = Depends(get_db)):
    today = date.today()
    result = await db.execute(
        select(Word)
        .where(
            Word.familiarity_score == 1,
            Word.next_review_date <= today,
        )
        .order_by(Word.priority_score.desc())
        .limit(30)
    )
    words = result.scalars().all()

    if not words:
        return StudyPlanResponse(rationale="No words due for review.", words=[])

    # Build context for each word
    queue_data = []
    for w in words:
        ctx = await _get_context(db, w.id)
        queue_data.append({
            "id": w.id,
            "word": w.traditional,
            "pinyin": w.pinyin or "",
            "definition": w.definition or "",
            "priority_score": float(w.priority_score or 0),
            "context": ctx or "",
        })

    prompt = (
        "You are a Mandarin learning coach. From the student's current learning queue, "
        "select the 10-15 most valuable words to study today. Prioritize: high frequency/diversity words, "
        "variety of topics, and natural learning progression.\n\n"
        "Return ONLY valid JSON (no markdown):\n"
        '{"rationale": "<2-3 sentence coaching note>", "word_ids": [<ids>]}\n\n'
        "Learning queue:\n"
        + json.dumps(queue_data, ensure_ascii=False)
    )

    rationale = "Showing your highest-priority words due for review today."
    selected_ids: set[int] = {w["id"] for w in queue_data[:15]}

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if api_key:
        try:
            import anthropic
            client = anthropic.Anthropic(api_key=api_key)
            message = client.messages.create(
                model="claude-haiku-4-5-20251001",
                max_tokens=500,
                temperature=0,
                messages=[{"role": "user", "content": prompt}],
            )
            raw = message.content[0].text.strip()
            ai_result = json.loads(raw)
            rationale = ai_result.get("rationale", rationale)
            selected_ids = set(int(i) for i in ai_result.get("word_ids", []))
        except Exception:
            pass  # fall through to default selection

    id_to_word = {w.id: w for w in words}
    id_to_ctx = {item["id"]: item["context"] for item in queue_data}

    result_words = []
    for wid in selected_ids:
        if wid in id_to_word:
            w = id_to_word[wid]
            result_words.append(WordQueueItem(
                id=w.id,
                traditional=w.traditional,
                pinyin=w.pinyin,
                definition=w.definition,
                priority_score=float(w.priority_score or 0),
                encounter_count=w.encounter_count,
                context_sentence=id_to_ctx.get(wid) or None,
            ))

    return StudyPlanResponse(rationale=rationale, words=result_words)


@router.get("/study/free", response_model=FreeStudyResponse)
async def get_free_study(db: AsyncSession = Depends(get_db)):
    known_result = await db.execute(
        select(Word)
        .where(Word.familiarity_score == 2)
        .order_by(Word.priority_score.desc())
        .limit(10)
    )
    known_words = known_result.scalars().all()

    learning_result = await db.execute(
        select(Word)
        .where(Word.familiarity_score == 1)
        .order_by(Word.last_reviewed.desc().nullslast())
        .limit(10)
    )
    learning_words = learning_result.scalars().all()

    known_items = [await _word_to_queue_item(db, w) for w in known_words]
    learning_items = [await _word_to_queue_item(db, w) for w in learning_words]

    return FreeStudyResponse(known_practice=known_items, new_learning=learning_items)
