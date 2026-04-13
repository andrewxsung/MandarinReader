import Foundation
import Combine

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
    @Published private(set) var pendingReviews: [PendingReview] = []
    @Published private(set) var isSessionComplete: Bool = false

    // MARK: - Private state

    private var words: [WordQueueItem] = []
    private var cardIndex: Int = 0
    private var roundResults: [Bool] = []   // per-round correct flags, reset per card

    nonisolated deinit { }

    // MARK: - Derived

    var currentWord: WordQueueItem? {
        guard !isSessionComplete, cardIndex < words.count else { return nil }
        return words[cardIndex]
    }

    var totalWords: Int { words.count }

    // MARK: - Lifecycle

    func start(words: [WordQueueItem]) {
        self.words = words
        self.cardIndex = 0
        self.currentRound = 1
        self.roundResults = []
        self.pendingReviews = []
        if words.isEmpty {
            self.isSessionComplete = true
            self.phase = .summary
        } else {
            self.isSessionComplete = false
            self.phase = .flash
        }
    }

    // MARK: - Transitions

    func advanceFromFlash() {
        guard phase == .flash else { return }
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
        pendingReviews.append(PendingReview(wordId: word.id, result: result))

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
