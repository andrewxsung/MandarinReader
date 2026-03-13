from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from ..database import get_db
from ..crud import get_queue
from ..schemas import WordQueueItem

router = APIRouter()


@router.get("/queue", response_model=list[WordQueueItem])
async def queue(n: int = Query(default=20, ge=1, le=100), db: AsyncSession = Depends(get_db)):
    items = await get_queue(db, n)
    return [
        WordQueueItem(
            id=word.id,
            traditional=word.traditional,
            pinyin=word.pinyin,
            definition=word.definition,
            priority_score=float(word.priority_score),
            encounter_count=word.encounter_count,
            context_sentence=context,
        )
        for word, context in items
    ]
