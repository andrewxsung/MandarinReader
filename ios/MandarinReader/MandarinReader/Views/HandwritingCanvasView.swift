import SwiftUI

/// Conversion between the square canvas's view coordinates and the
/// 1024×1024 top-left-origin data space used by stroke data and matching.
/// No y-flip here: BundleStrokeDataStore already flips the data at load.
enum CanvasCoordinates {
    static let dataSpaceSide: CGFloat = 1024

    static func toDataSpace(_ point: CGPoint, canvasSide: CGFloat) -> CGPoint {
        let k = dataSpaceSide / canvasSide
        return CGPoint(x: point.x * k, y: point.y * k)
    }

    static func displayScale(canvasSide: CGFloat) -> CGFloat {
        canvasSide / dataSpaceSide
    }
}

/// The writing surface for one character: 米字格 guide grid, live ink while
/// the finger/Pencil is down, accepted strokes rendered as clean typeset
/// fills, a fading red ghost for rejected strokes, and a pulsing hint
/// overlay of the expected stroke. Quiz logic lives in the parent; this view
/// only reports finished strokes (already converted to data space).
struct HandwritingCanvasView: View {

    let character: HanziCharacterData
    let acceptedStrokeCount: Int
    /// Increment to flash the expected stroke as a hint.
    let hintTrigger: Int
    /// Increment to flash the last drawn stroke as a rejected ghost.
    let rejectTrigger: Int
    /// Called with the finished stroke's points in 1024 data space.
    let onStrokeEnded: ([CGPoint]) -> Void

    @State private var livePoints: [CGPoint] = []
    @State private var ghostPoints: [CGPoint] = []
    @State private var ghostOpacity: Double = 0
    @State private var hintOpacity: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let scale = CanvasCoordinates.displayScale(canvasSide: side)
            let inkWidth = side / 24

            ZStack {
                gridBackground(side: side)

                // Accepted strokes, snapped to the typeset glyph outlines.
                ForEach(0..<min(acceptedStrokeCount, character.strokes.count), id: \.self) { i in
                    Path(character.strokes[i].outline)
                        .applying(CGAffineTransform(scaleX: scale, y: scale))
                        .fill(Color.primary)
                }

                // Hint: the expected stroke's outline, pulsed in.
                if acceptedStrokeCount < character.strokes.count {
                    Path(character.strokes[acceptedStrokeCount].outline)
                        .applying(CGAffineTransform(scaleX: scale, y: scale))
                        .fill(Color.accentColor)
                        .opacity(hintOpacity * 0.35)
                }

                // Rejected stroke ghost, fading out.
                inkPath(through: ghostPoints, width: inkWidth)
                    .foregroundStyle(Color.red)
                    .opacity(ghostOpacity * 0.6)

                // Live ink while drawing.
                inkPath(through: livePoints, width: inkWidth)
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        livePoints.append(value.location)
                    }
                    .onEnded { _ in
                        let points = livePoints.map {
                            CanvasCoordinates.toDataSpace($0, canvasSide: side)
                        }
                        ghostPoints = livePoints
                        livePoints = []
                        onStrokeEnded(points)
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: rejectTrigger) { _ in flashGhost() }
        .onChange(of: acceptedStrokeCount) { _ in
            ghostOpacity = 0
            hintOpacity = 0
        }
        .onChange(of: hintTrigger) { _ in flashHint() }
    }

    // MARK: - Layers

    private func inkPath(through points: [CGPoint], width: CGFloat) -> some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        .stroke(style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func gridBackground(side: CGFloat) -> some View {
        Path { path in
            // Border
            path.addRect(CGRect(x: 0, y: 0, width: side, height: side))
            // Midlines
            path.move(to: CGPoint(x: side / 2, y: 0))
            path.addLine(to: CGPoint(x: side / 2, y: side))
            path.move(to: CGPoint(x: 0, y: side / 2))
            path.addLine(to: CGPoint(x: side, y: side / 2))
            // Diagonals
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: side, y: side))
            path.move(to: CGPoint(x: side, y: 0))
            path.addLine(to: CGPoint(x: 0, y: side))
        }
        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
        .foregroundStyle(Color(.separator))
        .background(Color(.systemBackground))
    }

    // MARK: - Animations

    private func flashGhost() {
        ghostOpacity = 1
        withAnimation(.easeOut(duration: 0.4)) {
            ghostOpacity = 0
        }
    }

    private func flashHint() {
        withAnimation(.easeIn(duration: 0.25)) {
            hintOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.8).delay(0.6)) {
            hintOpacity = 0
        }
    }
}

#Preview {
    struct PreviewHost: View {
        @State private var quiz = HandwritingQuiz(
            characters: [BundleStrokeDataStore().data(for: "我")!]
        )
        @State private var hintTrigger = 0
        @State private var rejectTrigger = 0
        @State private var lastOutcome = "draw the first stroke of 我"

        var body: some View {
            VStack(spacing: 16) {
                Text(lastOutcome)
                if let character = quiz.currentCharacter {
                    HandwritingCanvasView(
                        character: character,
                        acceptedStrokeCount: quiz.acceptedStrokeCount,
                        hintTrigger: hintTrigger,
                        rejectTrigger: rejectTrigger
                    ) { points in
                        let outcome = quiz.submitStroke(points)
                        lastOutcome = "\(outcome)"
                        if case .rejected(let showHint, _) = outcome {
                            rejectTrigger += 1
                            if showHint { hintTrigger += 1 }
                        }
                    }
                    .padding()
                } else {
                    Text("完成! correct: \(quiz.isCorrect ? "yes" : "no")")
                }
            }
        }
    }
    return PreviewHost()
}
