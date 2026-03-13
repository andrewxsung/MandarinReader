from datetime import date, datetime
from sqlalchemy import (
    Integer, Text, Numeric, Date, TIMESTAMP, ForeignKey, Enum as SAEnum, Index
)
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import Mapped, mapped_column, relationship
from .database import Base

import enum


class SourceType(str, enum.Enum):
    extension_page = "extension_page"
    manual_paste = "manual_paste"
    camera = "camera"


class CedictEntry(Base):
    __tablename__ = "cedict"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    traditional: Mapped[str] = mapped_column(Text, nullable=False)
    simplified: Mapped[str] = mapped_column(Text, nullable=False)
    pinyin: Mapped[str] = mapped_column(Text, nullable=False)
    definitions: Mapped[list[str]] = mapped_column(ARRAY(Text), nullable=False)


class Word(Base):
    __tablename__ = "words"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    traditional: Mapped[str] = mapped_column(Text, nullable=False, unique=True)
    pinyin: Mapped[str | None] = mapped_column(Text)
    definition: Mapped[str | None] = mapped_column(Text)
    hsk_tier: Mapped[int | None] = mapped_column(Integer)
    familiarity_score: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    encounter_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    source_diversity_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    priority_score: Mapped[float] = mapped_column(Numeric(10, 4), nullable=False, default=0)
    next_review_date: Mapped[date | None] = mapped_column(Date)
    last_reviewed: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
    ease_factor: Mapped[float] = mapped_column(Numeric(4, 2), nullable=False, default=2.5)
    srs_interval_days: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), nullable=False)

    encounters: Mapped[list["Encounter"]] = relationship(back_populates="word", cascade="all, delete-orphan")


class Encounter(Base):
    __tablename__ = "encounters"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    word_id: Mapped[int] = mapped_column(Integer, ForeignKey("words.id", ondelete="CASCADE"), nullable=False)
    source_type: Mapped[SourceType] = mapped_column(SAEnum(SourceType, name="source_type_enum"), nullable=False)
    source_url: Mapped[str | None] = mapped_column(Text)
    context_sentence: Mapped[str | None] = mapped_column(Text)
    encountered_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), nullable=False)

    word: Mapped["Word"] = relationship(back_populates="encounters")


class Page(Base):
    __tablename__ = "pages"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    url: Mapped[str] = mapped_column(Text, nullable=False)
    title: Mapped[str | None] = mapped_column(Text)
    page_purpose: Mapped[str | None] = mapped_column(Text)
    captured_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), nullable=False)
