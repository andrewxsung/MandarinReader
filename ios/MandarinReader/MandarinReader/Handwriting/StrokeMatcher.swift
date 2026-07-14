import CoreGraphics

struct StrokeMatchResult: Equatable {
    let isMatch: Bool
    let isStrokeBackwards: Bool
}

/// Port of hanzi-writer's strokeMatches.ts: decides whether a drawn stroke
/// matches the expected stroke of a character. All points are in the
/// top-left-origin 1024×1024 data space produced by BundleStrokeDataStore.
enum StrokeMatcher {

    private static let cosineSimilarityThreshold: CGFloat = 0
    private static let startAndEndDistThreshold: CGFloat = 250
    private static let frechetThreshold: CGFloat = 0.4
    private static let minLengthThreshold: CGFloat = 0.35
    private static let averageDistanceThreshold: CGFloat = 350
    private static let shapeFitRotations: [CGFloat] = [.pi / 16, .pi / 32, 0, -.pi / 32, -.pi / 16]

    static func match(userPoints: [CGPoint],
                      strokeIndex: Int,
                      in character: HanziCharacterData,
                      leniency: CGFloat = 1,
                      isOutlineVisible: Bool = false) -> StrokeMatchResult {
        guard strokeIndex < character.strokes.count else {
            return StrokeMatchResult(isMatch: false, isStrokeBackwards: false)
        }
        let points = stripDuplicates(userPoints)
        guard points.count >= 2 else {
            return StrokeMatchResult(isMatch: false, isStrokeBackwards: false)
        }

        let expected = character.strokes[strokeIndex]
        let match = matchData(points: points, stroke: expected,
                              leniency: leniency, isOutlineVisible: isOutlineVisible)
        guard match.isMatch else {
            return StrokeMatchResult(isMatch: false, isStrokeBackwards: match.isStrokeBackwards)
        }

        // If a stroke the user hasn't drawn yet matches even closer, they
        // probably drew the wrong stroke: retry with tightened leniency
        // instead of failing outright.
        var closestMatchDist = match.avgDist
        for later in character.strokes.dropFirst(strokeIndex + 1) {
            let laterMatch = matchData(points: points, stroke: later,
                                       leniency: leniency, isOutlineVisible: isOutlineVisible,
                                       checkBackwards: false)
            if laterMatch.isMatch && laterMatch.avgDist < closestMatchDist {
                closestMatchDist = laterMatch.avgDist
            }
        }
        if closestMatchDist < match.avgDist {
            let leniencyAdjustment = 0.6 * (closestMatchDist + match.avgDist) / (2 * match.avgDist)
            let adjusted = matchData(points: points, stroke: expected,
                                     leniency: leniency * leniencyAdjustment,
                                     isOutlineVisible: isOutlineVisible)
            return StrokeMatchResult(isMatch: adjusted.isMatch,
                                     isStrokeBackwards: adjusted.isStrokeBackwards)
        }

        return StrokeMatchResult(isMatch: true, isStrokeBackwards: false)
    }

    // MARK: - Per-stroke match

    private struct MatchData {
        let isMatch: Bool
        let isStrokeBackwards: Bool
        let avgDist: CGFloat
    }

    private static func matchData(points: [CGPoint],
                                  stroke: HanziStroke,
                                  leniency: CGFloat,
                                  isOutlineVisible: Bool,
                                  checkBackwards: Bool = true) -> MatchData {
        let avgDist = averageDistance(from: points, to: stroke.median)
        let distMod: CGFloat = (isOutlineVisible || stroke.index > 0) ? 0.5 : 1
        guard avgDist <= averageDistanceThreshold * distMod * leniency else {
            return MatchData(isMatch: false, isStrokeBackwards: false, avgDist: avgDist)
        }

        let isMatch = startAndEndMatch(points: points, median: stroke.median, leniency: leniency)
            && directionMatch(points: points, median: stroke.median)
            && shapeFit(points, stroke.median, leniency: leniency)
            && lengthMatch(points: points, median: stroke.median, leniency: leniency)

        if checkBackwards && !isMatch {
            let backwards = matchData(points: points.reversed(), stroke: stroke,
                                      leniency: leniency, isOutlineVisible: isOutlineVisible,
                                      checkBackwards: false)
            if backwards.isMatch {
                return MatchData(isMatch: false, isStrokeBackwards: true, avgDist: avgDist)
            }
        }
        return MatchData(isMatch: isMatch, isStrokeBackwards: false, avgDist: avgDist)
    }

    // MARK: - Checks

    /// Mean over the user's points of the distance to the closest median point.
    private static func averageDistance(from points: [CGPoint], to median: [CGPoint]) -> CGFloat {
        guard !points.isEmpty, !median.isEmpty else { return .infinity }
        let total = points.reduce(CGFloat(0)) { sum, point in
            sum + median.map { HanziGeometry.distance(point, $0) }.min()!
        }
        return total / CGFloat(points.count)
    }

    private static func startAndEndMatch(points: [CGPoint], median: [CGPoint], leniency: CGFloat) -> Bool {
        guard let medianStart = median.first, let medianEnd = median.last,
              let start = points.first, let end = points.last else { return false }
        return HanziGeometry.distance(medianStart, start) <= startAndEndDistThreshold * leniency
            && HanziGeometry.distance(medianEnd, end) <= startAndEndDistThreshold * leniency
    }

    private static func directionMatch(points: [CGPoint], median: [CGPoint]) -> Bool {
        let edgeVectors = vectors(of: points)
        let strokeVectors = vectors(of: median)
        guard !edgeVectors.isEmpty, !strokeVectors.isEmpty else { return false }
        let similarities = edgeVectors.map { edge in
            strokeVectors.map { HanziGeometry.cosineSimilarity($0, edge) }.max()!
        }
        let average = similarities.reduce(0, +) / CGFloat(similarities.count)
        return average > cosineSimilarityThreshold
    }

    private static func shapeFit(_ curve1: [CGPoint], _ curve2: [CGPoint], leniency: CGFloat) -> Bool {
        let norm1 = HanziGeometry.normalize(curve1)
        let norm2 = HanziGeometry.normalize(curve2)
        let minDist = shapeFitRotations
            .map { HanziGeometry.frechetDistance(norm1, HanziGeometry.rotate(norm2, by: $0)) }
            .min() ?? .infinity
        return minDist <= frechetThreshold * leniency
    }

    private static func lengthMatch(points: [CGPoint], median: [CGPoint], leniency: CGFloat) -> Bool {
        leniency * (HanziGeometry.length(of: points) + 25)
            / (HanziGeometry.length(of: median) + 25) >= minLengthThreshold
    }

    // MARK: - Helpers

    private static func vectors(of points: [CGPoint]) -> [CGVector] {
        zip(points, points.dropFirst()).map { CGVector(dx: $1.x - $0.x, dy: $1.y - $0.y) }
    }

    private static func stripDuplicates(_ points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for point in points.dropFirst() where point != result[result.count - 1] {
            result.append(point)
        }
        return result
    }
}
