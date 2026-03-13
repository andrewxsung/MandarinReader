from datetime import date, datetime
from typing import Literal
from pydantic import BaseModel


# --- Ingest ---

class WordInput(BaseModel):
    word: str
    context_sentence: str | None = None


class IngestRequest(BaseModel):
    url: str
    title: str | None = None
    page_purpose: str | None = None
    words: list[WordInput]
    source_type: Literal["extension_page", "manual_paste", "camera"] = "extension_page"


class IngestResponse(BaseModel):
    words_added: int
    words_updated: int
    page_id: int


# --- Queue ---

class WordQueueItem(BaseModel):
    id: int
    traditional: str
    pinyin: str | None
    definition: str | None
    priority_score: float
    encounter_count: int
    context_sentence: str | None

    model_config = {"from_attributes": True}


# --- Review ---

class ReviewRequest(BaseModel):
    result: Literal["known", "learning", "ignore"]


class ReviewResponse(BaseModel):
    id: int
    familiarity_score: int
    next_review_date: date | None
    ease_factor: float
    srs_interval_days: int


# --- Words ---

class WordStats(BaseModel):
    id: int
    traditional: str
    pinyin: str | None
    definition: str | None
    familiarity_score: int
    encounter_count: int
    source_diversity_count: int
    priority_score: float
    next_review_date: date | None
    last_reviewed: datetime | None
    created_at: datetime

    model_config = {"from_attributes": True}


class WordLookup(BaseModel):
    traditional: str
    pinyin: str | None
    definition: str | None
    in_corpus: bool
    familiarity_score: int | None
    encounter_count: int | None


# --- Study ---

class StudyPlanResponse(BaseModel):
    rationale: str
    words: list[WordQueueItem]


class FreeStudyResponse(BaseModel):
    known_practice: list[WordQueueItem]
    new_learning: list[WordQueueItem]
