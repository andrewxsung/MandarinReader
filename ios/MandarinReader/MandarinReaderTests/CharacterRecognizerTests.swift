import XCTest
import UIKit
@testable import MandarinReader

final class CharacterRecognizerTests: XCTestCase {

    /// Render a single Chinese character as large black text on a white background.
    /// Mimics a clean ink stroke for the Vision pipeline.
    private func renderCharacter(_ char: String, size: CGSize = CGSize(width: 400, height: 400)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 300),
                .foregroundColor: UIColor.black
            ]
            let attributed = NSAttributedString(string: char, attributes: attrs)
            let bounds = attributed.boundingRect(
                with: size,
                options: [.usesLineFragmentOrigin],
                context: nil)
            let origin = CGPoint(
                x: (size.width - bounds.width) / 2,
                y: (size.height - bounds.height) / 2)
            attributed.draw(at: origin)
        }
    }

    func test_recognize_returnsNilForBlankImage() async {
        let size = CGSize(width: 400, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        let blank = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        let recognizer = CharacterRecognizer()
        let result = await recognizer.recognize(image: blank)
        XCTAssertNil(result)
    }

    func test_recognize_returnsCharacterForRenderedText() async {
        let image = renderCharacter("好")
        let recognizer = CharacterRecognizer()
        let result = await recognizer.recognize(image: image)

        XCTAssertNotNil(result, "Recognizer returned nil for a rendered character")
        XCTAssertTrue(
            result?.contains("好") ?? false,
            "Expected result to contain '好', got: \(result ?? "nil")"
        )
    }

    func test_matches_returnsTrueWhenRecognizedStringContainsTarget() {
        let recognizer = CharacterRecognizer()
        XCTAssertTrue(recognizer.matches(recognized: "好", target: "好"))
        XCTAssertTrue(recognizer.matches(recognized: "你好", target: "好"))
        XCTAssertTrue(recognizer.matches(recognized: " 好 ", target: "好"))
    }

    func test_matches_returnsFalseForMismatch() {
        let recognizer = CharacterRecognizer()
        XCTAssertFalse(recognizer.matches(recognized: "你", target: "好"))
        XCTAssertFalse(recognizer.matches(recognized: "", target: "好"))
        XCTAssertFalse(recognizer.matches(recognized: nil, target: "好"))
    }
}
