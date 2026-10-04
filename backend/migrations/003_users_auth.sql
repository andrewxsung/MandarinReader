-- Accounts + per-user data. DESTRUCTIVE: wipes existing vocabulary data
-- (start-fresh decision — see docs/superpowers/specs/2026-08-08-accounts-and-server-side-claude-design.md).
-- Run: psql mandarinreader < migrations/003_users_auth.sql

BEGIN;

CREATE TABLE users (
    id            SERIAL PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,          -- stored lowercased
    password_hash TEXT NOT NULL,                 -- argon2id
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE sessions (
    id           SERIAL PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash   TEXT NOT NULL UNIQUE,           -- sha256 hex of the raw bearer token
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at   TIMESTAMPTZ NOT NULL,
    last_used_at TIMESTAMPTZ
);
CREATE INDEX idx_sessions_user_id ON sessions (user_id);

TRUNCATE encounters, words, pages RESTART IDENTITY CASCADE;

ALTER TABLE words ADD COLUMN user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE words DROP CONSTRAINT words_traditional_key;
ALTER TABLE words ADD CONSTRAINT words_user_traditional_key UNIQUE (user_id, traditional);
CREATE INDEX idx_words_user_id ON words (user_id);

ALTER TABLE pages ADD COLUMN user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE;
CREATE INDEX idx_pages_user_id ON pages (user_id);

COMMIT;
