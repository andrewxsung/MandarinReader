import CoreGraphics

/// Pure geometry helpers ported from hanzi-writer's geometry.ts.
/// Curves are point arrays; all functions are stateless.
enum HanziGeometry {

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Cosine of the angle between two vectors; 1 = same direction,
    /// -1 = opposite, 0 = orthogonal (or either vector zero-length).
    static func cosineSimilarity(_ v1: CGVector, _ v2: CGVector) -> CGFloat {
        let magnitude = (v1.dx * v1.dx + v1.dy * v1.dy).squareRoot()
            * (v2.dx * v2.dx + v2.dy * v2.dy).squareRoot()
        guard magnitude > 0 else { return 0 }
        return (v1.dx * v2.dx + v1.dy * v2.dy) / magnitude
    }

    /// Total arc length of a polyline.
    static func length(of curve: [CGPoint]) -> CGFloat {
        zip(curve, curve.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// Discrete Fréchet distance between two polylines.
    static func frechetDistance(_ c1: [CGPoint], _ c2: [CGPoint]) -> CGFloat {
        guard !c1.isEmpty, !c2.isEmpty else { return .infinity }
        var dp = [[CGFloat]](repeating: [CGFloat](repeating: 0, count: c2.count), count: c1.count)
        for i in 0..<c1.count {
            for j in 0..<c2.count {
                let d = distance(c1[i], c2[j])
                if i == 0 && j == 0 {
                    dp[i][j] = d
                } else if i == 0 {
                    dp[i][j] = max(dp[i][j - 1], d)
                } else if j == 0 {
                    dp[i][j] = max(dp[i - 1][j], d)
                } else {
                    dp[i][j] = max(min(dp[i - 1][j], dp[i - 1][j - 1], dp[i][j - 1]), d)
                }
            }
        }
        return dp[c1.count - 1][c2.count - 1]
    }

    /// Splits any segment longer than `maxSegmentLength` into evenly
    /// spaced sub-segments.
    static func subdivide(_ curve: [CGPoint], maxSegmentLength: CGFloat) -> [CGPoint] {
        guard let first = curve.first else { return [] }
        var result = [first]
        for point in curve.dropFirst() {
            let previous = result[result.count - 1]
            let segmentLength = distance(previous, point)
            if segmentLength > maxSegmentLength {
                let pieces = Int((segmentLength / maxSegmentLength).rounded(.up))
                for i in 1...pieces {
                    let t = CGFloat(i) / CGFloat(pieces)
                    result.append(CGPoint(x: previous.x + (point.x - previous.x) * t,
                                          y: previous.y + (point.y - previous.y) * t))
                }
            } else {
                result.append(point)
            }
        }
        return result
    }

    /// Resamples a polyline to exactly `count` points evenly spaced by
    /// cumulative arc length, preserving the end points.
    static func resample(_ curve: [CGPoint], to count: Int) -> [CGPoint] {
        guard count >= 2, let first = curve.first, let last = curve.last else { return curve }
        let totalLength = length(of: curve)
        let step = totalLength / CGFloat(count - 1)

        var result = [first]
        var remaining = Array(curve.dropFirst())
        var lastPoint = first
        for _ in 0..<(count - 2) {
            var remainingDistance = step
            while let next = remaining.first {
                let nextDistance = distance(lastPoint, next)
                if nextDistance < remainingDistance, remaining.count > 1 {
                    remainingDistance -= nextDistance
                    lastPoint = remaining.removeFirst()
                } else {
                    let t = nextDistance > 0 ? remainingDistance / nextDistance : 0
                    lastPoint = CGPoint(x: lastPoint.x + (next.x - lastPoint.x) * t,
                                        y: lastPoint.y + (next.y - lastPoint.y) * t)
                    break
                }
            }
            result.append(lastPoint)
        }
        result.append(last)
        return result
    }

    /// hanzi-writer's normalizeCurve: resample to 30 points, center on the
    /// centroid, scale by the RMS distance of the two end points from the
    /// centroid, then subdivide at 0.05.
    static func normalize(_ curve: [CGPoint]) -> [CGPoint] {
        let resampled = resample(curve, to: 30)
        guard !resampled.isEmpty else { return [] }

        let meanX = resampled.reduce(0) { $0 + $1.x } / CGFloat(resampled.count)
        let meanY = resampled.reduce(0) { $0 + $1.y } / CGFloat(resampled.count)
        let centered = resampled.map { CGPoint(x: $0.x - meanX, y: $0.y - meanY) }

        let first = centered[0]
        let last = centered[centered.count - 1]
        let rawScale = (((first.x * first.x + first.y * first.y)
            + (last.x * last.x + last.y * last.y)) / 2).squareRoot()
        let scale = max(rawScale, 1e-9) // dot-like strokes: avoid divide-by-zero
        let scaled = centered.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }

        return subdivide(scaled, maxSegmentLength: 0.05)
    }

    /// Rotates every point about the origin.
    static func rotate(_ curve: [CGPoint], by angle: CGFloat) -> [CGPoint] {
        let c = cos(angle)
        let s = sin(angle)
        return curve.map { CGPoint(x: c * $0.x - s * $0.y, y: s * $0.x + c * $0.y) }
    }
}
