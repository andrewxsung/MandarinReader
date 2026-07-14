import XCTest
import CoreGraphics
@testable import MandarinReader

@MainActor
final class HandwritingQuizTests: XCTestCase {

    private var store: BundleStrokeDataStore!

    override func setUp() {
        super.setUp()
        store = BundleStrokeDataStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func quiz(for word: String) throws -> HandwritingQuiz {
        let characters = try word.map { try XCTUnwrap(store.data(for: $0), "missing data for \($0)") }
        return HandwritingQuiz(characters: characters)
    }

    /// Points nowhere near any real stroke.
    private let garbage = [CGPoint(x: -3000, y: -3000), CGPoint(x: -2990, y: -2990)]

    /// The median of the quiz's current expected stroke — always a match.
    private func correctStroke(_ quiz: HandwritingQuiz) throws -> [CGPoint] {
        let char = try XCTUnwrap(quiz.currentCharacter)
        return char.strokes[quiz.strokeIndex].median
    }

    // MARK: - Accepting

    func test_acceptedStrokeAdvancesAndResetsPerStrokeMisses() throws {
        var quiz = try quiz(for: "十")
        _ = quiz.submitStroke(garbage)
        _ = quiz.submitStroke(garbage)
        XCTAssertEqual(quiz.missesOnCurrentStroke, 2)

        let outcome = quiz.submitStroke(try correctStroke(quiz))
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(quiz.strokeIndex, 1)
        XCTAssertEqual(quiz.acceptedStrokeCount, 1)
        XCTAssertEqual(quiz.missesOnCurrentStroke, 0)
        XCTAssertEqual(quiz.totalMisses, 2)
    }

    func test_singleCharacterWordCompletes() throws {
        var quiz = try quiz(for: "一")
        let outcome = quiz.submitStroke(try correctStroke(quiz))
        XCTAssertEqual(outcome, .wordComplete)
        XCTAssertTrue(quiz.isComplete)
        XCTAssertTrue(quiz.isCorrect)
        XCTAssertNil(quiz.currentCharacter)
    }

    func test_multiCharacterWordProgressesOneCharacterAtATime() throws {
        var quiz = try quiz(for: "十一")
        XCTAssertEqual(quiz.currentCharacter?.character, "十")
        XCTAssertEqual(quiz.completedCharacters, [])

        XCTAssertEqual(quiz.submitStroke(try correctStroke(quiz)), .accepted)
        XCTAssertEqual(quiz.submitStroke(try correctStroke(quiz)), .characterComplete)
        XCTAssertEqual(quiz.currentCharacter?.character, "一")
        XCTAssertEqual(quiz.completedCharacters, ["十"])
        XCTAssertEqual(quiz.acceptedStrokeCount, 0)

        XCTAssertEqual(quiz.submitStroke(try correctStroke(quiz)), .wordComplete)
        XCTAssertTrue(quiz.isComplete)
        XCTAssertEqual(quiz.completedCharacters, ["十", "一"])
    }

    // MARK: - Rejecting, hints, force-accept

    func test_thirdMissOnSameStrokeShowsHint() throws {
        var quiz = try quiz(for: "一")
        XCTAssertEqual(quiz.submitStroke(garbage), .rejected(showHint: false, backwards: false))
        XCTAssertEqual(quiz.submitStroke(garbage), .rejected(showHint: false, backwards: false))
        XCTAssertEqual(quiz.submitStroke(garbage), .rejected(showHint: true, backwards: false))
    }

    func test_backwardsStrokeFlaggedInRejection() throws {
        var quiz = try quiz(for: "一")
        let reversed = Array(try correctStroke(quiz).reversed())
        XCTAssertEqual(quiz.submitStroke(reversed), .rejected(showHint: false, backwards: true))
    }

    func test_sixthMissForceAcceptsStroke() throws {
        var quiz = try quiz(for: "十")
        for _ in 1...5 {
            if case .rejected = quiz.submitStroke(garbage) {} else {
                return XCTFail("expected rejection before force-accept threshold")
            }
        }
        let outcome = quiz.submitStroke(garbage)
        XCTAssertEqual(outcome, .acceptedForced)
        XCTAssertEqual(quiz.strokeIndex, 1)
        XCTAssertEqual(quiz.totalMisses, 6)
    }

    func test_forceAcceptOnFinalStrokeCompletesWordAsIncorrect() throws {
        var quiz = try quiz(for: "一")
        for _ in 1...5 { _ = quiz.submitStroke(garbage) }
        XCTAssertEqual(quiz.submitStroke(garbage), .wordComplete)
        XCTAssertTrue(quiz.isComplete)
        XCTAssertFalse(quiz.isCorrect) // 6 misses on a 1-stroke word
    }

    // MARK: - Grading

    func test_grading_oneMissOnTenStrokeWordIsCorrect() throws {
        var quiz = try quiz(for: "師") // 10 strokes
        _ = quiz.submitStroke(garbage)
        while !quiz.isComplete {
            _ = quiz.submitStroke(try correctStroke(quiz))
        }
        XCTAssertEqual(quiz.totalMisses, 1)
        XCTAssertTrue(quiz.isCorrect) // 0.1 < 0.2
    }

    func test_grading_twoMissesOnTenStrokeWordIsIncorrect() throws {
        var quiz = try quiz(for: "師")
        _ = quiz.submitStroke(garbage)
        _ = quiz.submitStroke(garbage)
        while !quiz.isComplete {
            _ = quiz.submitStroke(try correctStroke(quiz))
        }
        XCTAssertEqual(quiz.totalMisses, 2)
        XCTAssertFalse(quiz.isCorrect) // 0.2 is not < 0.2
    }

    // MARK: - Edge cases

    func test_submittingAfterCompletionIsInert() throws {
        var quiz = try quiz(for: "一")
        _ = quiz.submitStroke(try correctStroke(quiz))
        XCTAssertEqual(quiz.submitStroke(garbage), .wordComplete)
        XCTAssertEqual(quiz.totalMisses, 0)
    }

    func test_emptyWordIsCompleteImmediately() {
        let quiz = HandwritingQuiz(characters: [])
        XCTAssertTrue(quiz.isComplete)
        XCTAssertNil(quiz.currentCharacter)
    }
}
