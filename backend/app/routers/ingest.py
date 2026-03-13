from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from ..database import get_db
from ..crud import create_page, upsert_word, is_cjk
from ..schemas import IngestRequest, IngestResponse

router = APIRouter()


@router.post("/ingest", response_model=IngestResponse)
async def ingest(payload: IngestRequest, db: AsyncSession = Depends(get_db)):
    async with db.begin():
        page = await create_page(db, payload.url, payload.title, payload.page_purpose)

        added = 0
        updated = 0
        for word_input in payload.words:
            if not is_cjk(word_input.word):
                continue
            _, is_new = await upsert_word(
                db,
                word_input.word,
                payload.source_type,
                payload.url,
                word_input.context_sentence,
            )
            if is_new:
                added += 1
            else:
                updated += 1

    return IngestResponse(words_added=added, words_updated=updated, page_id=page.id)
