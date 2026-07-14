import SwiftUI

struct PracticeView: View {

    @ObservedObject var session: SessionViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var flashVisible = true
    @State private var showSummary = false
    @FocusState private var inputFocused: Bool

    // Handwriting quiz state. `handwritingAvailable` decides the input mode
    // per card: stroke canvas when the dataset covers every character of the
    // word, keyboard TextField fallback otherwise.
    @State private var strokeStore = BundleStrokeDataStore()
    @State private var handwritingAvailable = true
    @State private var quiz: HandwritingQuiz?
    @State private var hintTrigger = 0
    @State private var rejectTrigger = 0

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
                    resetInput()
                    quiz = nil
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
                            .stroke(inputBorderColor, lineWidth: 3)
                    )

                if handwritingAvailable {
                    handwritingPanel(for: word)
                } else {
                    keyboardPanel
                }

                if case .feedback(let correct) = session.phase {
                    FeedbackOverlay(character: word.traditional, correct: correct)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal)

            controls()
                .padding(.horizontal)
                .padding(.bottom)
        }
        .task(id: word.id) {
            quiz = nil
            handwritingAvailable = strokeStore.hasData(forWord: word.traditional)
            if session.phase == .flash {
                flashVisible = true
                inputFocused = false
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return  // cancelled (e.g. user skipped) — don't touch VM state
                }
                flashVisible = false
                session.advanceFromFlash(for: word.id)
            }
        }
        .onChange(of: session.phase) { newPhase in
            guard newPhase == .writing else { return }
            if handwritingAvailable {
                prepareQuiz(for: word)
            } else {
                inputFocused = true
            }
        }
    }

    // MARK: - Input panels

    @ViewBuilder
    private var keyboardPanel: some View {
        VStack(spacing: 12) {
            TextField("", text: $input)
                .font(.system(size: 120, weight: .regular))
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($inputFocused)
                .disabled(session.phase != .writing)
                .onSubmit { if session.phase == .writing { submit() } }

            Text("Use the Chinese handwriting keyboard")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private func handwritingPanel(for word: WordQueueItem) -> some View {
        VStack(spacing: 12) {
            characterProgressRow(for: word)

            if let quiz, let character = quiz.currentCharacter {
                HandwritingCanvasView(
                    character: character,
                    acceptedStrokeCount: quiz.acceptedStrokeCount,
                    hintTrigger: hintTrigger,
                    rejectTrigger: rejectTrigger,
                    onStrokeEnded: { handleStroke($0, for: word) }
                )
            } else if let quiz, quiz.isComplete, let last = quiz.characters.last {
                // Word finished: keep the last character on display under the
                // feedback overlay.
                HandwritingCanvasView(
                    character: last,
                    acceptedStrokeCount: last.strokes.count,
                    hintTrigger: 0,
                    rejectTrigger: 0,
                    onStrokeEnded: { _ in }
                )
            } else {
                // Flash phase: empty writing surface.
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                    .aspectRatio(1, contentMode: .fit)
            }

            Text("Write each character stroke by stroke")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private func characterProgressRow(for word: WordQueueItem) -> some View {
        let completedCount = quiz?.characterIndex ?? 0
        HStack(spacing: 12) {
            ForEach(Array(word.traditional.enumerated()), id: \.offset) { index, char in
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(index == completedCount && session.phase == .writing
                                ? Color.accentColor : Color(.separator),
                                lineWidth: index == completedCount && session.phase == .writing ? 2 : 1)
                    if index < completedCount || quiz?.isComplete == true {
                        Text(String(char))
                            .font(.system(size: 36))
                    } else {
                        Circle()
                            .fill(Color(.tertiarySystemFill))
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(width: 52, height: 52)
            }
        }
    }

    // MARK: - Stroke handling

    private func handleStroke(_ points: [CGPoint], for word: WordQueueItem) {
        guard session.phase == .writing, quiz != nil else { return }
        guard let outcome = quiz?.submitStroke(points) else { return }

        switch outcome {
        case .accepted, .acceptedForced, .characterComplete:
            break
        case .rejected(let showHint, _):
            rejectTrigger += 1
            if showHint { hintTrigger += 1 }
        case .wordComplete:
            let correct = quiz?.isCorrect ?? false
            // Let the final stroke visibly snap into place before feedback.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard session.currentWord?.id == word.id else { return }
                session.submit(correct: correct)
            }
        }
    }

    private func prepareQuiz(for word: WordQueueItem) {
        let characters = word.traditional.compactMap { strokeStore.data(for: $0) }
        guard characters.count == word.traditional.count, !characters.isEmpty else {
            handwritingAvailable = false
            inputFocused = true
            return
        }
        quiz = HandwritingQuiz(characters: characters)
    }

    // MARK: - Info bar

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

    // MARK: - Controls

    @ViewBuilder
    private func controls() -> some View {
        HStack(spacing: 12) {
            if !handwritingAvailable {
                Button("Clear") {
                    resetInput()
                    inputFocused = true
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(session.phase != .writing)
            }

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
        case .writing: return handwritingAvailable ? "Write the word above" : "Submit"
        case .feedback(true): return session.isFinalRound ? "Next Word →" : "Next Round →"
        case .feedback(false): return session.isFinalRound ? "Next Word →" : "Try Again →"
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
        case .writing:
            return handwritingAvailable
                || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .flash:
            return true
        default:
            return false
        }
    }

    private var inputBorderColor: Color {
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
            if !handwritingAvailable { submit() }
        case .feedback:
            session.advanceRound()
            resetInput()
            if session.isSessionComplete {
                showSummary = true
            } else if !handwritingAvailable {
                inputFocused = true
            }
        default:
            break
        }
    }

    private func submit() {
        guard let word = session.currentWord else { return }
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let correct = typed == word.traditional
        inputFocused = false
        session.submit(correct: correct)
    }

    private func resetInput() {
        input = ""
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
