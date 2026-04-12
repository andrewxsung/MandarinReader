import XCTest
@testable import MandarinReader

final class ModelsTests: XCTestCase {

    func test_WordQueueItem_decodesFromBackendJSON() throws {
        let json = """
        {
            "id": 42,
            "traditional": "記住",
            "pinyin": "ji4 zhu4",
            "definition": "to remember",
            "priority_score": 5.25,
            "encounter_count": 3,
            "context_sentence": "請你記住我的名字。"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let word = try decoder.decode(WordQueueItem.self, from: json)

        XCTAssertEqual(word.id, 42)
        XCTAssertEqual(word.traditional, "記住")
        XCTAssertEqual(word.pinyin, "ji4 zhu4")
        XCTAssertEqual(word.definition, "to remember")
        XCTAssertEqual(word.priorityScore, 5.25, accuracy: 0.001)
        XCTAssertEqual(word.encounterCount, 3)
        XCTAssertEqual(word.contextSentence, "請你記住我的名字。")
    }

    func test_WordQueueItem_decodesWithNullOptionalFields() throws {
        let json = """
        {
            "id": 1,
            "traditional": "書",
            "pinyin": null,
            "definition": null,
            "priority_score": 0.5,
            "encounter_count": 1,
            "context_sentence": null
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let word = try decoder.decode(WordQueueItem.self, from: json)

        XCTAssertNil(word.pinyin)
        XCTAssertNil(word.definition)
        XCTAssertNil(word.contextSentence)
        XCTAssertEqual(word.traditional, "書")
    }

    func test_ReviewRequest_encodesToSnakeCaseJSON() throws {
        let request = ReviewRequest(result: .known)

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: String]

        XCTAssertEqual(dict["result"], "known")
    }

    func test_ReviewRequest_encodesLearningResult() throws {
        let request = ReviewRequest(result: .learning)

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: String]

        XCTAssertEqual(dict["result"], "learning")
    }

    func test_PendingReview_holdsWordIdAndResult() {
        let review = PendingReview(wordId: 7, result: .known)
        XCTAssertEqual(review.wordId, 7)
        XCTAssertEqual(review.result, .known)
    }
}
