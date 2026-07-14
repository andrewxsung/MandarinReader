import SwiftUI

/// Colored character + badge shown over the canvas after Submit.
struct FeedbackOverlay: View {
    let character: String
    let correct: Bool

    private var color: Color { correct ? .green : .red }

    var body: some View {
        ZStack {
            Text(character)
                .font(.system(size: 280, weight: .regular))
                .foregroundStyle(color.opacity(0.6))

            VStack {
                HStack {
                    Spacer()
                    Circle()
                        .fill(color)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: correct ? "checkmark" : "xmark")
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                        )
                        .padding(12)
                }
                Spacer()
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ZStack {
        Color.white
        FeedbackOverlay(character: "好", correct: true)
    }
    .frame(height: 500)
}
