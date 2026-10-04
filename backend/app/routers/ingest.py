import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_current_user
from ..crud import create_page, is_cjk, upsert_word
from ..database import get_db
from ..models import Page, User
from ..schemas import IngestRequest, IngestResponse
from ..services import claude

logger = logging.getLogger(__name__)

router = APIRouter()

DAILY_CAPTURE_LIMIT = 50


@router.post("/ingest", response_model=IngestResponse)
async def ingest(
    payload: IngestRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    user_id = user.id  # read before rollback, which expires loaded instances
    day_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    captures_today = await db.scalar(
        select(func.count(Page.id)).where(Page.user_id == user_id, Page.captured_at >= day_start)
    )
    # Close the read transaction before the (slow) Claude call so we don't
    # hold a DB connection open for seconds.
    await db.rollback()
    if captures_today >= DAILY_CAPTURE_LIMIT:
        raise HTTPException(status_code=429, detail="Daily capture limit reached — try again tomorrow")

    try:
        analysis = await claude.analyze_page(payload.page_text)
    except claude.AnalysisError as exc:
        logger.warning("page analysis failed for user %s: %s", user_id, exc)
        raise HTTPException(status_code=502, detail="Analysis failed — try again")

    page = await create_page(db, user_id, payload.url, payload.title, analysis.page_purpose)
    added = 0
    updated = 0
    for extracted in analysis.key_words:
        word = extracted.word.strip()  # " 貓" and "貓" must be the same word
        if not is_cjk(word):
            continue
        _, is_new = await upsert_word(
            db, user_id, word, "extension_page", payload.url, extracted.context_sentence
        )
        if is_new:
            added += 1
        else:
            updated += 1
    await db.commit()

    return IngestResponse(
        words_added=added,
        words_updated=updated,
        page_id=page.id,
        page_purpose=analysis.page_purpose,
        total_words=len(analysis.key_words),
    )
