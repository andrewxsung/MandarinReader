import XCTest
import CoreGraphics
@testable import MandarinReader

@MainActor
final class StrokeDataStoreTests: XCTestCase {

    private var store: BundleStrokeDataStore!

    override func setUp() {
        super.setUp()
        store = BundleStrokeDataStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func test_data_loadsSingleStrokeCharacterFromBundle() throws {
        let data = try XCTUnwrap(store.data(for: "一"))
        XCTAssertEqual(data.character, "一")
        XCTAssertEqual(data.strokes.count, 1)
        XCTAssertEqual(data.strokes[0].index, 0)
        XCTAssertFalse(data.strokes[0].median.isEmpty)
        XCTAssertFalse(data.strokes[0].outline.isEmpty)
    }

    func test_data_loadsTraditionalCharacter() throws {
        let data = try XCTUnwrap(store.data(for: "師"))
        XCTAssertEqual(data.strokes.count, 10)
    }

    func test_data_flipsMedianIntoTopLeftSpace() throws {
        // Raw first median point of 一 is [121, 393] in y-up space;
        // flipped via y' = 900 - y it becomes (121, 507).
        let data = try XCTUnwrap(store.data(for: "一"))
        XCTAssertEqual(data.strokes[0].median[0], CGPoint(x: 121, y: 507))
    }

    func test_data_flipsOutlineIntoTopLeftSpace() throws {
        // Raw outline of 一 starts with "M 518 382" → flipped (518, 518).
        let data = try XCTUnwrap(store.data(for: "一"))
        var firstPoint: CGPoint?
        data.strokes[0].outline.applyWithBlock { el in
            if firstPoint == nil, el.pointee.type == .moveToPoint {
                firstPoint = el.pointee.points[0]
            }
        }
        XCTAssertEqual(firstPoint, CGPoint(x: 518, y: 518))
    }

    func test_data_returnsNilForCharacterNotInDataset() {
        XCTAssertNil(store.data(for: "A"))
    }

    func test_data_isStableAcrossRepeatedCalls() throws {
        let first = try XCTUnwrap(store.data(for: "師"))
        let second = try XCTUnwrap(store.data(for: "師"))
        XCTAssertEqual(first.strokes.count, second.strokes.count)
        XCTAssertEqual(first.strokes[0].median, second.strokes[0].median)
    }

    func test_hasDataForWord_trueWhenAllCharactersCovered() {
        XCTAssertTrue(store.hasData(forWord: "老師"))
    }

    func test_hasDataForWord_falseWhenAnyCharacterMissing() {
        XCTAssertFalse(store.hasData(forWord: "老A"))
        XCTAssertFalse(store.hasData(forWord: ""))
    }
}
