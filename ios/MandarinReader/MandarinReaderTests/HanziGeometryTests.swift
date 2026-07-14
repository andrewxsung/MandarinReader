import XCTest
import CoreGraphics
@testable import MandarinReader

@MainActor
final class HanziGeometryTests: XCTestCase {

    // MARK: - distance / length / cosine

    func test_distance_isEuclidean() {
        XCTAssertEqual(HanziGeometry.distance(CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4)), 5)
    }

    func test_length_sumsSegments() {
        let curve = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4), CGPoint(x: 3, y: 14)]
        XCTAssertEqual(HanziGeometry.length(of: curve), 15)
    }

    func test_cosineSimilarity_parallelOppositeOrthogonal() {
        let right = CGVector(dx: 1, dy: 0)
        XCTAssertEqual(HanziGeometry.cosineSimilarity(right, CGVector(dx: 5, dy: 0)), 1, accuracy: 1e-9)
        XCTAssertEqual(HanziGeometry.cosineSimilarity(right, CGVector(dx: -2, dy: 0)), -1, accuracy: 1e-9)
        XCTAssertEqual(HanziGeometry.cosineSimilarity(right, CGVector(dx: 0, dy: 3)), 0, accuracy: 1e-9)
    }

    // MARK: - Fréchet

    func test_frechetDistance_identicalCurvesIsZero() {
        let curve = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 0)]
        XCTAssertEqual(HanziGeometry.frechetDistance(curve, curve), 0, accuracy: 1e-9)
    }

    func test_frechetDistance_parallelLinesIsSeparation() {
        let c1 = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)]
        let c2 = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 1)]
        XCTAssertEqual(HanziGeometry.frechetDistance(c1, c2), 1, accuracy: 1e-9)
    }

    // MARK: - subdivide

    func test_subdivide_leavesNoSegmentLongerThanMax() {
        let curve = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]
        let result = HanziGeometry.subdivide(curve, maxSegmentLength: 0.3)
        XCTAssertEqual(result.first, curve.first)
        XCTAssertEqual(result.last, curve.last)
        for (a, b) in zip(result, result.dropFirst()) {
            XCTAssertLessThanOrEqual(HanziGeometry.distance(a, b), 0.3 + 1e-9)
        }
    }

    func test_subdivide_keepsShortSegmentsUntouched() {
        let curve = [CGPoint(x: 0, y: 0), CGPoint(x: 0.1, y: 0), CGPoint(x: 0.2, y: 0)]
        XCTAssertEqual(HanziGeometry.subdivide(curve, maxSegmentLength: 0.3), curve)
    }

    // MARK: - resample

    func test_resample_returnsExactCountEvenlySpaced() {
        let curve = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        let result = HanziGeometry.resample(curve, to: 30)
        XCTAssertEqual(result.count, 30)
        XCTAssertEqual(result.first, CGPoint(x: 0, y: 0))
        XCTAssertEqual(result.last, CGPoint(x: 10, y: 0))
        let step = 10.0 / 29.0
        for (i, point) in result.enumerated() {
            XCTAssertEqual(point.x, CGFloat(i) * step, accuracy: 1e-6)
            XCTAssertEqual(point.y, 0, accuracy: 1e-9)
        }
    }

    func test_resample_preservesEndpointsOnBentCurve() {
        let curve = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 0)]
        let result = HanziGeometry.resample(curve, to: 10)
        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(result.first, curve.first)
        XCTAssertEqual(result.last, curve.last)
    }

    // MARK: - normalize

    func test_normalize_invariantUnderTranslationAndScale() {
        let curve = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 2), CGPoint(x: 8, y: 0)]
        let transformed = curve.map { CGPoint(x: $0.x * 3 + 100, y: $0.y * 3 - 40) }
        let n1 = HanziGeometry.normalize(curve)
        let n2 = HanziGeometry.normalize(transformed)
        XCTAssertEqual(n1.count, n2.count)
        for (a, b) in zip(n1, n2) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
    }

    func test_normalize_degenerateCurveDoesNotProduceNaN() {
        let dot = [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)]
        let result = HanziGeometry.normalize(dot)
        XCTAssertFalse(result.isEmpty)
        for point in result {
            XCTAssertFalse(point.x.isNaN)
            XCTAssertFalse(point.y.isNaN)
        }
    }

    // MARK: - rotate

    func test_rotate_quarterTurnAboutOrigin() {
        let result = HanziGeometry.rotate([CGPoint(x: 1, y: 0)], by: .pi / 2)
        XCTAssertEqual(result[0].x, 0, accuracy: 1e-9)
        XCTAssertEqual(result[0].y, 1, accuracy: 1e-9)
    }
}
