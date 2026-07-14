import XCTest
import CoreGraphics
@testable import MandarinReader

@MainActor
final class StrokeMatcherTests: XCTestCase {

    private var store: BundleStrokeDataStore!

    override func setUp() {
        super.setUp()
        store = BundleStrokeDataStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func character(_ char: Character) throws -> HanziCharacterData {
        try XCTUnwrap(store.data(for: char), "missing stroke data for \(char)")
    }

    /// A synthetic character with two identical horizontal strokes, used to
    /// isolate index-dependent behavior from real-glyph geometry.
    private func twinStrokeCharacter() -> HanziCharacterData {
        let median = [CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500)]
        let strokes = (0..<2).map {
            HanziStroke(index: $0, outline: CGMutablePath(), median: median)
        }
        return HanziCharacterData(character: "𝍖", strokes: strokes)
    }

    // MARK: - Accepting correct strokes

    func test_medianItselfMatchesItsOwnStroke() throws {
        let char = try character("我")
        for stroke in char.strokes {
            let result = StrokeMatcher.match(userPoints: stroke.median,
                                             strokeIndex: stroke.index,
                                             in: char)
            XCTAssertTrue(result.isMatch, "stroke \(stroke.index) of 我 should match its own median")
            XCTAssertFalse(result.isStrokeBackwards)
        }
    }

    func test_jitteredMedianStillMatches() throws {
        let char = try character("師")
        let jittered = HanziGeometry.resample(char.strokes[0].median, to: 40)
            .enumerated()
            .map { i, p in CGPoint(x: p.x + (i.isMultiple(of: 2) ? 12 : -12),
                                   y: p.y + (i.isMultiple(of: 3) ? -10 : 10)) }
        let result = StrokeMatcher.match(userPoints: jittered, strokeIndex: 0, in: char)
        XCTAssertTrue(result.isMatch)
    }

    // MARK: - Rejecting wrong strokes

    func test_reversedStrokeIsRejectedAndFlaggedBackwards() throws {
        let char = try character("一")
        let reversed = Array(char.strokes[0].median.reversed())
        let result = StrokeMatcher.match(userPoints: reversed, strokeIndex: 0, in: char)
        XCTAssertFalse(result.isMatch)
        XCTAssertTrue(result.isStrokeBackwards)
    }

    func test_wrongStrokeOutOfOrderIsRejected() throws {
        // 十: stroke 0 is the horizontal, stroke 1 the vertical. Drawing the
        // vertical while the horizontal is expected must fail (order enforced).
        let char = try character("十")
        let vertical = char.strokes[1].median
        let result = StrokeMatcher.match(userPoints: vertical, strokeIndex: 0, in: char)
        XCTAssertFalse(result.isMatch)
    }

    func test_grosslyShortStrokeIsRejected() throws {
        let char = try character("一")
        let start = char.strokes[0].median[0]
        let tiny = [start, CGPoint(x: start.x + 20, y: start.y)]
        let result = StrokeMatcher.match(userPoints: tiny, strokeIndex: 0, in: char)
        XCTAssertFalse(result.isMatch)
    }

    func test_farAwayStrokeIsRejected() throws {
        let char = try character("一")
        let offset = char.strokes[0].median.map { CGPoint(x: $0.x + 400, y: $0.y + 400) }
        let result = StrokeMatcher.match(userPoints: offset, strokeIndex: 0, in: char)
        XCTAssertFalse(result.isMatch)
    }

    func test_fewerThanTwoDistinctPointsIsRejected() throws {
        let char = try character("一")
        let point = char.strokes[0].median[0]
        XCTAssertFalse(StrokeMatcher.match(userPoints: [point, point], strokeIndex: 0, in: char).isMatch)
        XCTAssertFalse(StrokeMatcher.match(userPoints: [], strokeIndex: 0, in: char).isMatch)
    }

    // MARK: - Threshold behavior

    func test_distanceThresholdHalvesForLaterStrokes() {
        // Identical strokes at index 0 and 1; a 240-unit offset passes the
        // 350 threshold at index 0 but fails the halved 175 threshold at index 1.
        let char = twinStrokeCharacter()
        let offset = char.strokes[0].median.map { CGPoint(x: $0.x, y: $0.y + 240) }
        XCTAssertTrue(StrokeMatcher.match(userPoints: offset, strokeIndex: 0, in: char).isMatch)
        XCTAssertFalse(StrokeMatcher.match(userPoints: offset, strokeIndex: 1, in: char).isMatch)
    }

    func test_leniencyLoosensDistanceThreshold() {
        let char = twinStrokeCharacter()
        let offset = char.strokes[0].median.map { CGPoint(x: $0.x, y: $0.y + 240) }
        // 240 > 175 fails at leniency 1 (index 1), but 240 <= 175 * 2 passes at 2.
        XCTAssertFalse(StrokeMatcher.match(userPoints: offset, strokeIndex: 1, in: char).isMatch)
        XCTAssertTrue(StrokeMatcher.match(userPoints: offset, strokeIndex: 1, in: char, leniency: 2).isMatch)
    }
}
