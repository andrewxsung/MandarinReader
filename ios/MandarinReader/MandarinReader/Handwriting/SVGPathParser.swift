import CoreGraphics

/// Parses the SVG path strings found in hanzi-writer-data stroke outlines.
/// The dataset only ever uses absolute M, L, Q, C, and Z commands; anything
/// else throws so a data-format surprise fails loudly in tests.
enum SVGPathParser {

    enum ParseError: Error, Equatable {
        case unsupportedCommand(Character)
        case malformedNumber(String)
        case unexpectedEnd
    }

    static func parse(_ d: String) throws -> CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(tokens: d)

        while let token = scanner.next() {
            switch token {
            case .command(let command):
                try apply(command, to: path, scanner: &scanner)
            case .number(let text):
                // A bare number outside a command context can only follow a
                // completed command group: SVG implicit repetition. The scanner
                // pushes it back and `apply` re-reads it via the repeat loop,
                // so reaching here means the path started with a number.
                throw ParseError.malformedNumber(text)
            }
        }
        return path
    }

    // MARK: - Command application

    private static func apply(_ command: Character, to path: CGMutablePath, scanner: inout Scanner) throws {
        switch command {
        case "M":
            repeat {
                path.move(to: try scanner.point())
            } while scanner.nextIsNumber()
        case "L":
            repeat {
                path.addLine(to: try scanner.point())
            } while scanner.nextIsNumber()
        case "Q":
            repeat {
                let control = try scanner.point()
                let end = try scanner.point()
                path.addQuadCurve(to: end, control: control)
            } while scanner.nextIsNumber()
        case "C":
            repeat {
                let c1 = try scanner.point()
                let c2 = try scanner.point()
                let end = try scanner.point()
                path.addCurve(to: end, control1: c1, control2: c2)
            } while scanner.nextIsNumber()
        case "Z":
            path.closeSubpath()
        default:
            throw ParseError.unsupportedCommand(command)
        }
    }

    // MARK: - Tokenizer

    private enum Token {
        case command(Character)
        case number(String)
    }

    private struct Scanner {
        private let tokens: [Token]
        private var index = 0

        init(tokens d: String) {
            var result: [Token] = []
            var current = ""
            func flushNumber() {
                if !current.isEmpty {
                    result.append(.number(current))
                    current = ""
                }
            }
            for ch in d {
                if ch.isLetter {
                    flushNumber()
                    result.append(.command(ch))
                } else if ch.isWhitespace || ch == "," {
                    flushNumber()
                } else {
                    current.append(ch)
                }
            }
            flushNumber()
            self.tokens = result
        }

        mutating func next() -> Token? {
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tokens[index]
        }

        func nextIsNumber() -> Bool {
            guard index < tokens.count, case .number = tokens[index] else { return false }
            return true
        }

        mutating func number() throws -> CGFloat {
            guard index < tokens.count else { throw ParseError.unexpectedEnd }
            guard case .number(let text) = tokens[index] else { throw ParseError.unexpectedEnd }
            guard let value = Double(text) else { throw ParseError.malformedNumber(text) }
            index += 1
            return CGFloat(value)
        }

        mutating func point() throws -> CGPoint {
            CGPoint(x: try number(), y: try number())
        }
    }
}
