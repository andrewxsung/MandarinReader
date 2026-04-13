import SwiftUI
import PencilKit

struct PracticeView: View {

    @ObservedObject var session: SessionViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var drawing = PKDrawing()
    @State private var isRecognizing = false
    @State private var flashVisible = true
    @State private var showSummary = false

    private let recognizer = CharacterRecognizer()

    var body: some View {
        Group {
            if let word = session.currentWord {
                practiceContent(for: word)
            } else if session.isSessionComplete {
                Color.clear
                    .onAppear { showSummary = true }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationDestination(isPresented: $showSummary) {
            SummaryView(session: session)
        }
    }

    @ViewBuilder
    private func practiceContent(for word: WordQueueItem) -> some View {
        VStack(spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    ForEach(0..<3) { idx in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(dotColor(for: idx))
                            .frame(width: 40, height: 8)
                    }
                }
                Spacer()
                Button("Skip →") {
                    resetCanvas()
                    session.skip()
                    if session.isSessionComplete { showSummary = true }
                }
                .font(.body)
            }
            .padding(.horizontal)

            infoBar(for: word)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(canvasBorderColor, lineWidth: 3)
                    )

                PKCanvasWrapper(drawing: $drawing)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(session.phase == .writing)

                if case .feedback(let correct) = session.phase {
                    FeedbackOverlay(character: word.traditional, correct: correct)
                }

                if isRecognizing {
                    ProgressView().scaleEffect(1.5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal)

            controls()
                .padding(.horizontal)
                .padding(.bottom)
        }
        .task(id: word.id) {
            if session.phase == .flash {
                flashVisible = true
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                flashVisible = false
                session.advanceFromFlash()
            }
        }
    }

    @ViewBuilder
    private func infoBar(for word: WordQueueItem) -> some View {
        VStack(spacing: 4) {
            if session.phase == .flash && flashVisible {
                Text(word.traditional)
                    .font(.system(size: 100, weight: .regular))
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                if let pinyin = word.pinyin, !pinyin.isEmpty {
                    Text(pinyin).font(.title3).foregroundStyle(.secondary)
                }
                if word.pinyin != nil && word.definition != nil {
                    Text("·").foregroundStyle(.secondary)
                }
                if let definition = word.definition, !definition.isEmpty {
                    Text(definition).font(.title3).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func controls() -> some View {
        HStack(spacing: 12) {
            Button("Clear") {
                resetCanvas()
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(session.phase != .writing)

            Button(primaryButtonTitle) {
                primaryAction()
            }
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding()
            .background(primaryButtonColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(primaryDisabled)
        }
    }

    private var primaryButtonTitle: String {
        switch session.phase {
        case .flash: return "…"
        case .writing: return "Submit"
        case .feedback(true): return "Next Round →"
        case .feedback(false): return "Try Again →"
        case .summary: return "Done"
        }
    }

    private var primaryButtonColor: Color {
        switch session.phase {
        case .feedback(true): return .green
        case .feedback(false): return .red
        default: return .accentColor
        }
    }

    private var primaryDisabled: Bool {
        switch session.phase {
        case .writing: return drawing.strokes.isEmpty || isRecognizing
        case .flash: return true
        default: return false
        }
    }

    private var canvasBorderColor: Color {
        switch session.phase {
        case .feedback(true): return .green
        case .feedback(false): return .red
        default: return Color(.separator)
        }
    }

    private func dotColor(for idx: Int) -> Color {
        let round = idx + 1
        if round < session.currentRound {
            return Color.accentColor.opacity(0.8)
        }
        if round == session.currentRound {
            if case .feedback(let correct) = session.phase {
                return correct ? .green : .red
            }
            return Color.accentColor
        }
        return Color(.tertiarySystemFill)
    }

    private func primaryAction() {
        switch session.phase {
        case .writing:
            submitForRecognition()
        case .feedback:
            session.advanceRound()
            resetCanvas()
            if session.isSessionComplete { showSummary = true }
        default:
            break
        }
    }

    private func submitForRecognition() {
        guard let word = session.currentWord else { return }
        isRecognizing = true
        let canvasSize = CGSize(width: 600, height: 600)
        let image = drawing.rasterize(size: canvasSize)
        Task {
            let recognized = await recognizer.recognize(image: image)
            let correct = recognizer.matches(recognized: recognized, target: word.traditional)
            await MainActor.run {
                isRecognizing = false
                session.submit(correct: correct)
            }
        }
    }

    private func resetCanvas() {
        drawing = PKDrawing()
    }
}

#Preview {
    let session = SessionViewModel()
    session.start(words: [
        WordQueueItem(id: 1, traditional: "記住", pinyin: "ji4 zhu4",
                      definition: "to remember", priorityScore: 1.0,
                      encounterCount: 1, contextSentence: nil)
    ])
    return NavigationStack {
        PracticeView(session: session)
            .environmentObject(AppSettings())
    }
}
