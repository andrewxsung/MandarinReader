# iPadOS Handwriting Practice App — Design Spec

**Date:** 2026-04-12  
**Status:** Approved

---

## Overview

A native iPadOS app for practicing Traditional Chinese vocabulary through Apple Pencil handwriting. Words are pulled from the existing MandarinReader backend queue. The learning interaction is flash-then-recall: the character is shown briefly, hidden, and the user must reproduce it from memory. Apple's on-device Vision framework recognizes what the user wrote and provides immediate feedback.

---

## Architecture

**Platform:** iPadOS 16+, native SwiftUI  
**No local database.** All session state lives in memory. The backend is the single source of truth.

Three layers:

### Network Layer
- `URLSession` for all API calls
- Fetches queue at session start: `GET /api/queue?n=20`
- Batches review results at session end: `POST /api/review/{word_id}` (fired in parallel for all completed cards)
- Authenticates via `X-API-Key` header (matches existing backend auth)

### Session Layer
- `SessionViewModel` (ObservableObject) owns all session state
- Holds `[WordQueueItem]` fetched at start — immutable for the duration of the session
- Accumulates `[PendingReview]` as the user completes cards: `{ word_id, result }` where result is `"known"` or `"learning"`
- Tracks current card index and round (1–3) within a card

### UI Layer
- SwiftUI views driven by `SessionViewModel`
- `PKCanvasView` (PencilKit) for the drawing surface, wrapped in a `UIViewRepresentable`
- `VNRecognizeTextRequest` (Vision) for character recognition, run on a background thread

---

## Session Flow

### Session Start
1. App displays a "Start Session" screen with a configurable word count (default 20)
2. Tap Start → `GET /api/queue?n=N` → words loaded into `SessionViewModel`
3. First card appears immediately

### Per-Card Flow (3 rounds)

**Flash phase (3 seconds) — once per card, before round 1 only:**
- Character, pinyin, and definition displayed prominently
- After 3 seconds, character fades out; pinyin and definition remain visible for all 3 rounds
- Rounds 2 and 3 skip the flash and go directly to the write phase

**Write phase:**
- Blank `PKCanvasView` presented
- User writes with Apple Pencil
- "Clear" button resets the canvas without submitting
- "Skip — I know this" button available at any time; skipping counts as `"known"` and advances to the next card immediately

**Submit → Recognition:**
1. `PKDrawing.image(from:scale:)` renders canvas to `UIImage`
2. `VNImageRequestHandler` created with the image
3. `VNRecognizeTextRequest` runs with:
   - `recognitionLanguages: ["zh-Hant"]`
   - `recognitionLevel: .accurate`
   - `usesLanguageCorrection: false`
4. Top candidate string extracted; exact-matched against `word.traditional`
5. If Vision returns no result (blank/unrecognizable): treated as incorrect

**Feedback display:**
- Canvas border turns green (correct) or red (incorrect)
- User's strokes remain faint on canvas
- Correct character overlays in color (green or red) at ~60% opacity
- Badge (✓ or ✗) appears top-right of canvas
- Progress dot for the current round updates to reflect the result
- Button changes to "Next Round →" (correct) or "Try Again →" (incorrect)

**Round tracking:**
- Rounds 1–3 play through sequentially; correct/incorrect result stored per round
- After round 3: if 2 or more rounds correct → `"known"`, otherwise → `"learning"`
- Result appended to `[PendingReview]`, advance to next card

### Session End

After the final card, a summary screen shows:
- Total cards completed
- Score: e.g. "14 known · 6 to practice"
- Word-by-word breakdown (word, result)
- "Sync Results" button

**Sync flow:**
1. Tap "Sync Results" → spinner appears
2. All `POST /api/review/{word_id}` calls fired in parallel via `withTaskGroup`
3. Success → "Done — results synced" + "Start New Session" button
4. Failure → error message + "Retry" button (results remain in memory, safe to retry)

---

## UI Design

**Layout:** Minimal / Focused (works in both portrait and landscape)

**Practice screen structure (top to bottom):**
1. **Progress row** — three dots (colored per result: pending = gray, correct = green, incorrect = red) on the left; "Skip →" link on the right
2. **Info bar** — pinyin · English definition (always visible after flash phase)
3. **Canvas** — `PKCanvasView` fills the remaining vertical space; white background, black ink
4. **Controls row** — "Clear" (secondary) + "Submit" (primary) side by side

**Feedback states:**
- Correct: green canvas border, green character overlay, ✓ badge, "Next Round →" button
- Incorrect: red canvas border, red character overlay, ✗ badge, "Try Again →" button

---

## Data Model

```swift
// Matches backend GET /api/queue response
struct WordQueueItem: Decodable {
    let id: Int
    let traditional: String
    let pinyin: String?
    let definition: String?
    let priorityScore: Double
    let encounterCount: Int
    let contextSentence: String?
}

// Accumulated during session, submitted at end
struct PendingReview {
    let wordId: Int
    let result: String  // "known" | "learning"
}
```

---

## Backend Integration

The app talks to the existing MandarinReader FastAPI backend unchanged. No new endpoints needed.

| Action | Endpoint | Notes |
|---|---|---|
| Fetch queue | `GET /api/queue?n=20` | Called once at session start |
| Submit review | `POST /api/review/{word_id}` | Body: `{"result": "known"\|"learning"}` |

Auth: `X-API-Key: <user-configured key>` header on all requests.

Backend URL and API key are stored in the app via a simple Settings screen (no iCloud sync — local only).

---

## Out of Scope (for now)

- Offline-first / persistent local storage
- Stroke order guidance
- Stroke-level recognition feedback
- Simplified Chinese support
- iCloud sync
- Improvements to the priority queue algorithm (tracked separately in MandarinReader)

---

## Open Questions

None — all design decisions resolved during brainstorming.
