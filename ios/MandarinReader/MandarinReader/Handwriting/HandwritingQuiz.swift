import CoreGraphics

/// State machine for one round of writing a word stroke-by-stroke.
/// Plain struct held in view @State; grading thresholds are constants here.
struct HandwritingQuiz {

    static let hintAfterMisses = 3
    /// Anti-softlock: the stroke is accepted (still counted as missed) after
    /// this many failed attempts so a round can always finish.
    static let forceAcceptAfterMisses = 6
    /// Round is correct iff totalMisses / totalStrokes stays under this.
    static let maxMissRatio = 0.2

    enum StrokeOutcome: Equatable {
        case accepted
        case acceptedForced
        case rejected(showHint: Bool, backwards: Bool)
        case characterComplete
        case wordComplete
    }

    private(set) var characterIndex = 0
    private(set) var strokeIndex = 0
    private(set) var missesOnCurrentStroke = 0
    private(set) var totalMisses = 0

    let characters: [HanziCharacterData]
    let totalStrokes: Int

    init(characters: [HanziCharacterData]) {
        self.characters = characters
        self.totalStrokes = characters.reduce(0) { $0 + $1.strokes.count }
    }

    var currentCharacter: HanziCharacterData? {
        characterIndex < characters.count ? characters[characterIndex] : nil
    }

    /// Strokes of the current character already accepted (for rendering).
    var acceptedStrokeCount: Int { strokeIndex }

    var completedCharacters: [Character] {
        characters.prefix(characterIndex).map(\.character)
    }

    var isComplete: Bool { characterIndex >= characters.count }

    var isCorrect: Bool {
        guard totalStrokes > 0 else { return false }
        return Double(totalMisses) / Double(totalStrokes) < Self.maxMissRatio
    }

    mutating func submitStroke(_ points: [CGPoint]) -> StrokeOutcome {
        guard let character = currentCharacter else { return .wordComplete }

        let result = StrokeMatcher.match(userPoints: points,
                                         strokeIndex: strokeIndex,
                                         in: character)
        if result.isMatch {
            return accept(forced: false)
        }

        missesOnCurrentStroke += 1
        totalMisses += 1
        if missesOnCurrentStroke >= Self.forceAcceptAfterMisses {
            return accept(forced: true)
        }
        return .rejected(showHint: missesOnCurrentStroke >= Self.hintAfterMisses,
                         backwards: result.isStrokeBackwards)
    }

    private mutating func accept(forced: Bool) -> StrokeOutcome {
        guard let character = currentCharacter else { return .wordComplete }
        strokeIndex += 1
        missesOnCurrentStroke = 0
        if strokeIndex >= character.strokes.count {
            characterIndex += 1
            strokeIndex = 0
            return isComplete ? .wordComplete : .characterComplete
        }
        return forced ? .acceptedForced : .accepted
    }
}
