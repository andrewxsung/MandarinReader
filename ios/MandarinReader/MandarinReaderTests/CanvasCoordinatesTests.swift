import XCTest
import CoreGraphics
@testable import MandarinReader

@MainActor
final class CanvasCoordinatesTests: XCTestCase {

    func test_toDataSpace_scalesByInverseCanvasSide() {
        let converted = CanvasCoordinates.toDataSpace(CGPoint(x: 175, y: 350), canvasSide: 350)
        XCTAssertEqual(converted.x, 512, accuracy: 1e-9)
        XCTAssertEqual(converted.y, 1024, accuracy: 1e-9)
    }

    func test_displayScale_isInverseOfToDataSpace() {
        let scale = CanvasCoordinates.displayScale(canvasSide: 350)
        let point = CGPoint(x: 123, y: 45)
        let roundTripped = CanvasCoordinates.toDataSpace(
            CGPoint(x: point.x * scale, y: point.y * scale), canvasSide: 350)
        XCTAssertEqual(roundTripped.x, point.x, accuracy: 1e-6)
        XCTAssertEqual(roundTripped.y, point.y, accuracy: 1e-6)
    }

    /// The footgun guard: a stroke traced over the rendered glyph on a real
    /// canvas size must match once converted the same way the canvas does.
    func test_strokeTracedInViewCoordinatesMatchesAfterConversion() throws {
        let store = BundleStrokeDataStore()
        let char = try XCTUnwrap(store.data(for: "師"))
        let canvasSide: CGFloat = 350
        let scale = CanvasCoordinates.displayScale(canvasSide: canvasSide)

        // What the user traces on screen: the rendered median in view space.
        let tracedInView = char.strokes[0].median.map {
            CGPoint(x: $0.x * scale, y: $0.y * scale)
        }
        let converted = tracedInView.map {
            CanvasCoordinates.toDataSpace($0, canvasSide: canvasSide)
        }
        let result = StrokeMatcher.match(userPoints: converted, strokeIndex: 0, in: char)
        XCTAssertTrue(result.isMatch)
    }
}
