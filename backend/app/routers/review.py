from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ..database import get_db
from ..models import Word
from ..services.srs import apply_review
from ..services.priority import compute_priority
from ..schemas import ReviewRequest, ReviewResponse

router = APIRouter()


@router.post("/review/{word_id}", response_model=ReviewResponse)
async def review(word_id: int, payload: ReviewRequest, db: AsyncSession = Depends(get_db)):
    async with db.begin():
        result = await db.execute(
            select(Word).where(Word.id == word_id).with_for_update()
        )
        word = result.scalar_one_or_none()
        if word is None:
            raise HTTPException(status_code=404, detail="Word not found")

        apply_review(word, payload.result)
        word.priority_score = compute_priority(word)

    return ReviewResponse(
        id=word.id,
        familiarity_score=word.familiarity_score,
        next_review_date=word.next_review_date,
        ease_factor=float(word.ease_factor),
        srs_interval_days=word.srs_interval_days,
    )
