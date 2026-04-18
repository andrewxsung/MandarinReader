import Foundation

/// A word fetched from `GET /api/queue`. Fields mirror the backend's `WordQueueItem` schema.
struct WordQueueItem: Codable, Identifiable, Equatable {
    let id: Int
    let traditional: String
    let pinyin: String?
    let definition: String?
    let priorityScore: Double
    let encounterCount: Int
    let contextSentence: String?
}

/// The outcome of a single card review, submitted via `POST /api/review/{word_id}`.
/// Matches the backend `ReviewRequest` literal values.
enum ReviewResult: String, Codable, Equatable {
    case known
    case learning
    case ignore
}

/// Body of `POST /api/review/{word_id}`.
struct ReviewRequest: Codable {
    let result: ReviewResult
}

/// A completed card result waiting to be synced at session end.
/// Kept in memory on `SessionViewModel`. Carries `traditional`/`pinyin` so the
/// summary screen can show the character instead of just the numeric id.
struct PendingReview: Codable, Equatable {
    let wordId: Int
    let traditional: String
    let pinyin: String?
    let result: ReviewResult
}
