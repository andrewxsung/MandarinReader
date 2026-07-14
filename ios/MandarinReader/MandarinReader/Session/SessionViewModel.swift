import Foundation
import Combine

// MARK: - Persistence

/// Protocol abstraction over PendingReview persistence so the ViewModel can
/// be unit-tested without touching disk / UserDefaults.
protocol PendingReviewStore {
    func load() -> [PendingReview]
    func save(_ reviews: [PendingReview])
    func clear()
}

/// Production store. Serializes to JSON and writes to UserDefaults under a
/// single key. Load tolerates corrupt data by returning an empty list.
final class UserDefaultsPendingReviewStore: PendingReviewStore {
    private let defaults: UserDefaults
    private let key = "pendingReviews"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // Xcode 26 MainActor deinit back-deploy shim crashes libmalloc when
    // classes stored on a @MainActor owner lack an explicit nonisolated deinit.
    nonisolated deinit { }

    func load() -> [PendingReview] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingReview].self, from: data)) ?? []
    }

    func save(_ reviews: [PendingReview]) {
        guard let data = try? JSONEncoder().encode(reviews) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// Test double; also the default for tests that don't need persistence.
final class InMemoryPendingReviewStore: PendingReviewStore {
    var savedValue: [PendingReview] = []
    func load() -> [PendingReview] { savedValue }
    func save(_ reviews: [PendingReview]) { savedValue = reviews }
    func clear() { savedValue = [] }
    nonisolated deinit { }
}

// MARK: - SessionViewModel

/// Core state machine for a practice session. Owns the word list, tracks which card
/// and round the user is on, accumulates review results to sync at session end.
@MainActor
final class SessionViewModel: ObservableObject {

    enum Phase: Equatable {
        case flash
        case writing
        case feedback(correct: Bool)
        case summary
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase = .flash
    @Published private(set) var currentRound: Int = 1
    @Published private(set) var pendingReviews: [PendingReview] {
        didSet { store.save(pendingReviews) }
    }
    @Published private(set) var isSessionComplete: Bool = false

    // MARK: - Private state

    private let store: PendingReviewStore
    private var words: [WordQueueItem] = []
    private var cardIndex: Int = 0
    private var roundResults: [Bool] = []   // per-round correct flags, reset per card

    nonisolated deinit { }

    init(store: PendingReviewStore = InMemoryPendingReviewStore()) {
        self.store = store
        self.pendingReviews = store.load()
    }

    // MARK: - Derived

    var currentWord: WordQueueItem? {
        guard !isSessionComplete, cardIndex < words.count else { return nil }
        return words[cardIndex]
    }

    var totalWords: Int { words.count }

    /// True when we're on the final round of the current card. Drives UI labels
    /// that would otherwise lie ("Try Again →" on a round that doesn't loop back).
    var isFinalRound: Bool { currentRound >= 3 }

    // MARK: - Lifecycle

    /// Begins a new practice session. Does NOT clear `pendingReviews` — unsynced
    /// reviews from a killed or failed session are preserved until the caller
    /// explicitly invokes `clearPersistedReviews()`. The UI gates Start on
    /// `pendingReviews.isEmpty` so the two states never mix in one session.
    func start(words: [WordQueueItem]) {
        self.words = words
        self.cardIndex = 0
        self.currentRound = 1
        self.roundResults = []
        if words.isEmpty {
            self.isSessionComplete = true
            self.phase = .summary
        } else {
            self.isSessionComplete = false
            self.phase = .flash
        }
    }

    /// Called by SummaryView on successful sync and by the recovery banner on
    /// Discard. Clears both the in-memory list and the persistent store.
    func clearPersistedReviews() {
        pendingReviews = []
    }

    // MARK: - Transitions

    /// Advances from flash to writing for the card the caller thinks is current.
    /// `wordId` guards against stale calls from a cancelled SwiftUI `.task` whose
    /// resumption would otherwise end the next card's flash phase prematurely.
    func advanceFromFlash(for wordId: Int) {
        guard phase == .flash, currentWord?.id == wordId else { return }
        phase = .writing
    }

    func submit(correct: Bool) {
        guard phase == .writing else { return }
        phase = .feedback(correct: correct)
        roundResults.append(correct)
    }

    func advanceRound() {
        guard case .feedback = phase else { return }

        if currentRound < 3 {
            currentRound += 1
            phase = .writing
        } else {
            // Round 3 completed — compute card result and advance
            let correctCount = roundResults.filter { $0 }.count
            let result: ReviewResult = correctCount >= 2 ? .known : .learning
            completeCurrentCard(with: result)
        }
    }

    func skip() {
        guard let word = currentWord else { return }
        _ = word
        completeCurrentCard(with: .known)
    }

    // MARK: - Internal

    private func completeCurrentCard(with result: ReviewResult) {
        guard let word = currentWord else { return }
        pendingReviews.append(PendingReview(
            wordId: word.id,
            traditional: word.traditional,
            pinyin: word.pinyin,
            result: result
        ))

        cardIndex += 1
        roundResults = []
        currentRound = 1

        if cardIndex >= words.count {
            isSessionComplete = true
            phase = .summary
        } else {
            phase = .flash
        }
    }
}
