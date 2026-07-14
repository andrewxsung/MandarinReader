import CoreGraphics
import Foundation

/// On-disk shape of one hanzi-writer-data character JSON.
struct RawCharacterData: Decodable {
    let strokes: [String]
    let medians: [[[Double]]]
}

/// One stroke of a character, already converted into top-left-origin
/// 1024×1024 display space (the raw data is y-up with a −900 offset).
struct HanziStroke {
    let index: Int
    let outline: CGPath
    let median: [CGPoint]
}

struct HanziCharacterData {
    let character: Character
    let strokes: [HanziStroke]
}

protocol StrokeDataProviding {
    func data(for character: Character) -> HanziCharacterData?
    func hasData(forWord word: String) -> Bool
}

/// Loads character stroke data from the HanziWriterData.bundle resource
/// folder, flipping coordinates into top-left display space at load time.
final class BundleStrokeDataStore: StrokeDataProviding {

    private let bundle: Bundle
    private var cache: [Character: HanziCharacterData] = [:]

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    // Xcode 26 MainActor deinit back-deploy shim crashes libmalloc when
    // classes stored on a @MainActor owner lack an explicit nonisolated deinit.
    nonisolated deinit { }

    func data(for character: Character) -> HanziCharacterData? {
        if let cached = cache[character] { return cached }
        guard let url = bundle.url(forResource: String(character),
                                   withExtension: "json",
                                   subdirectory: "HanziWriterData.bundle"),
              let json = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(RawCharacterData.self, from: json),
              raw.strokes.count == raw.medians.count
        else { return nil }

        // Raw data is y-up on a 1024 em box offset by -900; flip into
        // top-left display space so views and touch input share one system.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 900)

        var strokes: [HanziStroke] = []
        for (index, (pathString, median)) in zip(raw.strokes, raw.medians).enumerated() {
            guard let parsed = try? SVGPathParser.parse(pathString),
                  let outline = parsed.copy(using: &flip)
            else { return nil }
            let points = median.compactMap { pair -> CGPoint? in
                guard pair.count >= 2 else { return nil }
                return CGPoint(x: pair[0], y: 900 - pair[1])
            }
            strokes.append(HanziStroke(index: index, outline: outline, median: points))
        }

        let result = HanziCharacterData(character: character, strokes: strokes)
        cache[character] = result
        return result
    }

    func hasData(forWord word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { data(for: $0) != nil }
    }
}
