from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from ..auth import get_current_user
from ..database import get_db
from ..crud import get_queue
from ..models import User
from ..schemas import WordQueueItem

router = APIRouter()


@router.get("/queue", response_model=list[WordQueueItem])
async def queue(
    n: int = Query(default=20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    items = await get_queue(db, user.id, n)
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
