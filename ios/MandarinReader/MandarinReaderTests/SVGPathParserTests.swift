import XCTest
import CoreGraphics
@testable import MandarinReader

final class SVGPathParserTests: XCTestCase {

    // MARK: - Helpers

    private struct Element: Equatable {
        let type: CGPathElementType
        let points: [CGPoint]
    }

    private func elements(of path: CGPath) -> [Element] {
        var result: [Element] = []
        path.applyWithBlock { el in
            let e = el.pointee
            let count: Int
            switch e.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            result.append(Element(type: e.type, points: (0..<count).map { e.points[$0] }))
        }
        return result
    }

    // MARK: - Tests

    func test_parse_moveLineClose() throws {
        let path = try SVGPathParser.parse("M 10 20 L 30 40 Z")
        XCTAssertEqual(elements(of: path), [
            Element(type: .moveToPoint, points: [CGPoint(x: 10, y: 20)]),
            Element(type: .addLineToPoint, points: [CGPoint(x: 30, y: 40)]),
            Element(type: .closeSubpath, points: []),
        ])
    }

    func test_parse_quadAndCubicCurves() throws {
        let path = try SVGPathParser.parse("M 0 0 Q 10 20 30 40 C 1 2 3 4 5 6 Z")
        XCTAssertEqual(elements(of: path), [
            Element(type: .moveToPoint, points: [.zero]),
            Element(type: .addQuadCurveToPoint,
                    points: [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)]),
            Element(type: .addCurveToPoint,
                    points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4), CGPoint(x: 5, y: 6)]),
            Element(type: .closeSubpath, points: []),
        ])
    }

    func test_parse_negativeAndDecimalNumbers() throws {
        let path = try SVGPathParser.parse("M -12.5 3.25 L 7 -8")
        XCTAssertEqual(elements(of: path), [
            Element(type: .moveToPoint, points: [CGPoint(x: -12.5, y: 3.25)]),
            Element(type: .addLineToPoint, points: [CGPoint(x: 7, y: -8)]),
        ])
    }

    func test_parse_implicitCommandRepetition() throws {
        let path = try SVGPathParser.parse("M 0 0 L 1 2 3 4")
        XCTAssertEqual(elements(of: path), [
            Element(type: .moveToPoint, points: [.zero]),
            Element(type: .addLineToPoint, points: [CGPoint(x: 1, y: 2)]),
            Element(type: .addLineToPoint, points: [CGPoint(x: 3, y: 4)]),
        ])
    }

    func test_parse_throwsOnUnsupportedCommand() {
        XCTAssertThrowsError(try SVGPathParser.parse("M 0 0 A 5 5 0 0 1 10 10")) { error in
            XCTAssertEqual(error as? SVGPathParser.ParseError, .unsupportedCommand("A"))
        }
    }

    func test_parse_throwsOnLowercaseCommand() {
        XCTAssertThrowsError(try SVGPathParser.parse("m 10 10")) { error in
            XCTAssertEqual(error as? SVGPathParser.ParseError, .unsupportedCommand("m"))
        }
    }

    func test_parse_realStrokeFromHanziWriterData() throws {
        // First stroke outline of 一 straight from the dataset.
        let d = "M 518 382 Q 572 385 623 389 Q 758 399 900 383 Q 928 379 935 390 Q 944 405 930 419 Q 896 452 845 475 Q 829 482 798 473 Q 723 460 480 434 Q 180 409 137 408 Q 130 408 124 408 Q 108 408 106 395 Q 105 380 127 363 Q 146 348 183 334 Q 195 330 216 338 Q 232 344 306 354 Q 400 373 518 382 Z"
        let path = try SVGPathParser.parse(d)
        let parsed = elements(of: path)
        XCTAssertEqual(parsed.first, Element(type: .moveToPoint, points: [CGPoint(x: 518, y: 382)]))
        XCTAssertEqual(parsed.last, Element(type: .closeSubpath, points: []))
        XCTAssertEqual(parsed.count, 17) // 1 move + 15 quads + 1 close
    }
}
