-- MandarinReader initial schema
-- Run: psql mandarinreader < migrations/001_initial_schema.sql

CREATE TYPE source_type_enum AS ENUM ('extension_page', 'manual_paste', 'camera');

-- CC-CEDICT reference table (read-only after import)
CREATE TABLE IF NOT EXISTS cedict (
    id          SERIAL PRIMARY KEY,
    traditional TEXT NOT NULL,
    simplified  TEXT NOT NULL,
    pinyin      TEXT NOT NULL,
    definitions TEXT[] NOT NULL,
    UNIQUE (traditional, pinyin)
);
CREATE INDEX IF NOT EXISTS idx_cedict_traditional ON cedict (traditional);

-- Core vocabulary table
CREATE TABLE IF NOT EXISTS words (
    id                     SERIAL PRIMARY KEY,
    traditional            TEXT NOT NULL UNIQUE,
    pinyin                 TEXT,
    definition             TEXT,
    hsk_tier               INTEGER,
    familiarity_score      INTEGER NOT NULL DEFAULT 0,
        -- -1=ignored, 0=unknown, 1=learning, 2=known
    encounter_count        INTEGER NOT NULL DEFAULT 0,
    source_diversity_count INTEGER NOT NULL DEFAULT 0,
    priority_score         NUMERIC(10,4) NOT NULL DEFAULT 0,
    next_review_date       DATE,
    last_reviewed          TIMESTAMPTZ,
    ease_factor            NUMERIC(4,2) NOT NULL DEFAULT 2.5,
    srs_interval_days      INTEGER NOT NULL DEFAULT 1,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_words_priority
    ON words (priority_score DESC) WHERE familiarity_score >= 0;
CREATE INDEX IF NOT EXISTS idx_words_next_review
    ON words (next_review_date) WHERE familiarity_score = 1;

-- Encounter log (append-only)
CREATE TABLE IF NOT EXISTS encounters (
    id               SERIAL PRIMARY KEY,
    word_id          INTEGER NOT NULL REFERENCES words(id) ON DELETE CASCADE,
    source_type      source_type_enum NOT NULL,
    source_url       TEXT,
    context_sentence TEXT,
    encountered_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_encounters_word_id ON encounters (word_id);

-- Page log
CREATE TABLE IF NOT EXISTS pages (
    id           SERIAL PRIMARY KEY,
    url          TEXT NOT NULL,
    title        TEXT,
    page_purpose TEXT,
    captured_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pages_url ON pages (url);

-- Auto-update updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS words_updated_at ON words;
CREATE TRIGGER words_updated_at
    BEFORE UPDATE ON words
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
