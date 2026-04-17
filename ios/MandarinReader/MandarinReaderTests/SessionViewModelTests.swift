import XCTest
@testable import MandarinReader

@MainActor
final class SessionViewModelTests: XCTestCase {

    private func makeWord(id: Int, char: String) -> WordQueueItem {
        WordQueueItem(
            id: id, traditional: char, pinyin: "test",
            definition: "test", priorityScore: 1.0,
            encounterCount: 1, contextSentence: nil
        )
    }

    private func makeSession(wordCount: Int = 2) -> SessionViewModel {
        let words = (1...wordCount).map { makeWord(id: $0, char: "字\($0)") }
        let vm = SessionViewModel()
        vm.start(words: words)
        return vm
    }

    // MARK: - start

    func test_start_setsFirstWordAndFlashPhase() {
        let vm = makeSession()
        XCTAssertEqual(vm.currentWord?.id, 1)
        XCTAssertEqual(vm.currentRound, 1)
        XCTAssertEqual(vm.phase, .flash)
        XCTAssertFalse(vm.isSessionComplete)
        XCTAssertEqual(vm.pendingReviews.count, 0)
    }

    func test_start_withEmptyWordsMarksSessionComplete() {
        let vm = SessionViewModel()
        vm.start(words: [])
        XCTAssertTrue(vm.isSessionComplete)
    }

    // MARK: - phase transitions

    func test_advanceFromFlash_movesToWriting() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        XCTAssertEqual(vm.phase, .writing)
    }

    func test_advanceFromFlash_forStaleWordId_isIgnored() {
        // Reproduces the race from PracticeView.task when Skip fires during flash:
        // the cancelled task resumes and calls advanceFromFlash on the NEW current word.
        let vm = makeSession()
        vm.skip()  // now on word 2, phase == .flash
        vm.advanceFromFlash(for: 1)  // stale call from word 1's cancelled task
        XCTAssertEqual(vm.phase, .flash, "stale call must not advance new word's flash")
        XCTAssertEqual(vm.currentWord?.id, 2)
    }

    func test_submit_correctMovesToFeedbackCorrect() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: true)
        XCTAssertEqual(vm.phase, .feedback(correct: true))
    }

    func test_submit_incorrectMovesToFeedbackIncorrect() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: false)
        XCTAssertEqual(vm.phase, .feedback(correct: false))
    }

    // MARK: - isFinalRound (drives UI labels that differ on the last round)

    func test_isFinalRound_falseOnRound1() {
        let vm = makeSession()
        XCTAssertFalse(vm.isFinalRound)
    }

    func test_isFinalRound_falseOnRound2() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: true); vm.advanceRound()
        XCTAssertEqual(vm.currentRound, 2)
        XCTAssertFalse(vm.isFinalRound)
    }

    func test_isFinalRound_trueOnRound3() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: true); vm.advanceRound()
        vm.submit(correct: true); vm.advanceRound()
        XCTAssertEqual(vm.currentRound, 3)
        XCTAssertTrue(vm.isFinalRound)
    }

    // MARK: - round advancement

    func test_advanceRound_fromRound1GoesToRound2Writing() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: true)
        vm.advanceRound()
        XCTAssertEqual(vm.currentRound, 2)
        XCTAssertEqual(vm.phase, .writing)
        XCTAssertEqual(vm.currentWord?.id, 1)  // still same word
    }

    func test_advanceRound_fromRound2GoesToRound3Writing() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: true); vm.advanceRound()
        vm.submit(correct: true); vm.advanceRound()
        XCTAssertEqual(vm.currentRound, 3)
        XCTAssertEqual(vm.phase, .writing)
    }

    // MARK: - card completion

    func test_allThreeRoundsCorrect_marksWordKnownAndAdvancesCard() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: true); vm.advanceRound()
        vm.submit(correct: true); vm.advanceRound()
        vm.submit(correct: true); vm.advanceRound()

        XCTAssertEqual(vm.pendingReviews.count, 1)
        XCTAssertEqual(vm.pendingReviews[0].wordId, 1)
        XCTAssertEqual(vm.pendingReviews[0].result, .known)
        XCTAssertEqual(vm.currentWord?.id, 2)
        XCTAssertEqual(vm.currentRound, 1)
        XCTAssertEqual(vm.phase, .flash)
    }

    func test_twoOfThreeCorrect_marksKnown() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: true); vm.advanceRound()
        vm.submit(correct: false); vm.advanceRound()
        vm.submit(correct: true); vm.advanceRound()

        XCTAssertEqual(vm.pendingReviews[0].result, .known)
    }

    func test_oneOfThreeCorrect_marksLearning() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: true); vm.advanceRound()
        vm.submit(correct: false); vm.advanceRound()
        vm.submit(correct: false); vm.advanceRound()

        XCTAssertEqual(vm.pendingReviews[0].result, .learning)
    }

    func test_zeroCorrect_marksLearning() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: false); vm.advanceRound()
        vm.submit(correct: false); vm.advanceRound()
        vm.submit(correct: false); vm.advanceRound()

        XCTAssertEqual(vm.pendingReviews[0].result, .learning)
    }

    // MARK: - skip

    func test_skip_marksKnownAndAdvancesCard() {
        let vm = makeSession()
        vm.skip()

        XCTAssertEqual(vm.pendingReviews.count, 1)
        XCTAssertEqual(vm.pendingReviews[0].wordId, 1)
        XCTAssertEqual(vm.pendingReviews[0].traditional, "字1")
        XCTAssertEqual(vm.pendingReviews[0].result, .known)
        XCTAssertEqual(vm.currentWord?.id, 2)
        XCTAssertEqual(vm.phase, .flash)
    }

    func test_pendingReview_preservesTraditionalAndPinyin() {
        // Summary screen must show the actual character, not "Word #42".
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: true); vm.advanceRound()
        vm.submit(correct: true); vm.advanceRound()
        vm.submit(correct: true); vm.advanceRound()

        let review = vm.pendingReviews[0]
        XCTAssertEqual(review.traditional, "字1")
        XCTAssertEqual(review.pinyin, "test")
    }

    func test_skip_mid_roundStillAdvances() {
        let vm = makeSession()
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: false); vm.advanceRound()
        vm.skip()

        XCTAssertEqual(vm.pendingReviews.count, 1)
        XCTAssertEqual(vm.pendingReviews[0].result, .known)
        XCTAssertEqual(vm.currentWord?.id, 2)
    }

    // MARK: - session completion

    func test_completingLastCardMarksSessionComplete() {
        let vm = makeSession(wordCount: 1)
        vm.advanceFromFlash(for: 1)
        vm.submit(correct: true); vm.advanceRound()
        vm.submit(correct: true); vm.advanceRound()
        vm.submit(correct: true); vm.advanceRound()

        XCTAssertTrue(vm.isSessionComplete)
        XCTAssertEqual(vm.phase, .summary)
        XCTAssertNil(vm.currentWord)
    }

    func test_skipOnLastCardCompletesSession() {
        let vm = makeSession(wordCount: 1)
        vm.skip()
        XCTAssertTrue(vm.isSessionComplete)
        XCTAssertEqual(vm.phase, .summary)
    }
}
