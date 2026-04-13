import Foundation
import UIKit
import Vision

/// Recognizes Traditional Chinese characters from a rendered image using Apple's Vision framework.
/// Runs entirely on-device; no network calls.
struct CharacterRecognizer {

    /// Returns the top recognized string, or nil if Vision produces no candidates.
    func recognize(image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let pieces = observations.compactMap { $0.topCandidates(1).first?.string }
                let joined = pieces.joined()
                continuation.resume(returning: joined.isEmpty ? nil : joined)
            }
            request.recognitionLanguages = ["zh-Hant"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Checks whether a recognized string contains the target character. Tolerates
    /// surrounding whitespace and multi-character recognition output.
    func matches(recognized: String?, target: String) -> Bool {
        guard let recognized = recognized else { return false }
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains(target)
    }
}
