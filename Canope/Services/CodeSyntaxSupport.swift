import AppKit
import Foundation

enum CodeSyntaxLanguage: String, Codable, Equatable {
    case python
    case r
}

enum CodeTokenKind: String, Codable, CaseIterable, Equatable {
    case comment
    case keyword
    case string
    case number
    case function
    case type
    case decorator
    case oper
}

struct CodeTokenSpan: Equatable {
    let range: NSRange
    let kind: CodeTokenKind
}

struct CodeSyntaxTheme: Equatable {
    let name: String
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let selectionColor: NSColor
    let cursorColor: NSColor
    let tokenColors: [CodeTokenKind: NSColor]

    func color(for kind: CodeTokenKind) -> NSColor {
        tokenColors[kind] ?? foregroundColor
    }

    static let monokai = CodeSyntaxTheme(
        name: "Monokai",
        backgroundColor: NSColor(srgbRed: 0.15, green: 0.16, blue: 0.13, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.94, alpha: 1),
        selectionColor: NSColor(srgbRed: 0.30, green: 0.30, blue: 0.25, alpha: 1),
        cursorColor: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.94, alpha: 1),
        tokenColors: [
            .comment: NSColor(srgbRed: 0.45, green: 0.45, blue: 0.39, alpha: 1),
            .keyword: NSColor(srgbRed: 0.40, green: 0.85, blue: 0.94, alpha: 1),
            .string: NSColor(srgbRed: 0.90, green: 0.86, blue: 0.45, alpha: 1),
            .number: NSColor(srgbRed: 0.70, green: 0.56, blue: 0.75, alpha: 1),
            .function: NSColor(srgbRed: 0.65, green: 0.89, blue: 0.18, alpha: 1),
            .type: NSColor(srgbRed: 0.40, green: 0.85, blue: 0.94, alpha: 1),
            .decorator: NSColor(srgbRed: 0.98, green: 0.15, blue: 0.45, alpha: 1),
            .oper: NSColor(srgbRed: 0.98, green: 0.15, blue: 0.45, alpha: 1),
        ]
    )

    static let kakuDark = CodeSyntaxTheme(
        name: "Kaku Dark",
        backgroundColor: NSColor(srgbRed: 0.082, green: 0.078, blue: 0.106, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0.929, green: 0.925, blue: 0.933, alpha: 1),
        selectionColor: NSColor(srgbRed: 0.2, green: 0.2, blue: 0.25, alpha: 1),
        cursorColor: NSColor(srgbRed: 0.929, green: 0.925, blue: 0.933, alpha: 1),
        tokenColors: [
            .comment: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.43, alpha: 1),
            .keyword: NSColor(srgbRed: 0.37, green: 0.66, blue: 1.0, alpha: 1),
            .string: NSColor(srgbRed: 0.38, green: 1.0, blue: 0.79, alpha: 1),
            .number: NSColor(srgbRed: 0.635, green: 0.467, blue: 1.0, alpha: 1),
            .function: NSColor(srgbRed: 0.635, green: 0.467, blue: 1.0, alpha: 1),
            .type: NSColor(srgbRed: 0.37, green: 0.66, blue: 1.0, alpha: 1),
            .decorator: NSColor(srgbRed: 1.0, green: 0.79, blue: 0.52, alpha: 1),
            .oper: NSColor(srgbRed: 1.0, green: 0.79, blue: 0.52, alpha: 1),
        ]
    )

    static let dracula = CodeSyntaxTheme(
        name: "Dracula",
        backgroundColor: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.21, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1),
        selectionColor: NSColor(srgbRed: 0.26, green: 0.26, blue: 0.35, alpha: 1),
        cursorColor: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1),
        tokenColors: [
            .comment: NSColor(srgbRed: 0.38, green: 0.45, blue: 0.55, alpha: 1),
            .keyword: NSColor(srgbRed: 0.94, green: 0.47, blue: 0.60, alpha: 1),
            .string: NSColor(srgbRed: 0.94, green: 0.98, blue: 0.55, alpha: 1),
            .number: NSColor(srgbRed: 0.70, green: 0.56, blue: 0.75, alpha: 1),
            .function: NSColor(srgbRed: 0.51, green: 0.93, blue: 0.98, alpha: 1),
            .type: NSColor(srgbRed: 0.51, green: 0.93, blue: 0.98, alpha: 1),
            .decorator: NSColor(srgbRed: 0.94, green: 0.47, blue: 0.60, alpha: 1),
            .oper: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.42, alpha: 1),
        ]
    )

    static let nord = CodeSyntaxTheme(
        name: "Nord",
        backgroundColor: NSColor(srgbRed: 0.18, green: 0.20, blue: 0.25, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0.85, green: 0.87, blue: 0.91, alpha: 1),
        selectionColor: NSColor(srgbRed: 0.26, green: 0.30, blue: 0.37, alpha: 1),
        cursorColor: NSColor(srgbRed: 0.85, green: 0.87, blue: 0.91, alpha: 1),
        tokenColors: [
            .comment: NSColor(srgbRed: 0.42, green: 0.48, blue: 0.55, alpha: 1),
            .keyword: NSColor(srgbRed: 0.53, green: 0.75, blue: 0.82, alpha: 1),
            .string: NSColor(srgbRed: 0.71, green: 0.81, blue: 0.66, alpha: 1),
            .number: NSColor(srgbRed: 0.70, green: 0.56, blue: 0.75, alpha: 1),
            .function: NSColor(srgbRed: 0.53, green: 0.75, blue: 0.82, alpha: 1),
            .type: NSColor(srgbRed: 0.53, green: 0.75, blue: 0.82, alpha: 1),
            .decorator: NSColor(srgbRed: 0.70, green: 0.56, blue: 0.75, alpha: 1),
            .oper: NSColor(srgbRed: 0.81, green: 0.63, blue: 0.48, alpha: 1),
        ]
    )

    static let solarized = CodeSyntaxTheme(
        name: "Solarized",
        backgroundColor: NSColor(srgbRed: 0.0, green: 0.17, blue: 0.21, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0.51, green: 0.58, blue: 0.59, alpha: 1),
        selectionColor: NSColor(srgbRed: 0.07, green: 0.26, blue: 0.33, alpha: 1),
        cursorColor: NSColor(srgbRed: 0.51, green: 0.58, blue: 0.59, alpha: 1),
        tokenColors: [
            .comment: NSColor(srgbRed: 0.35, green: 0.43, blue: 0.46, alpha: 1),
            .keyword: NSColor(srgbRed: 0.15, green: 0.55, blue: 0.82, alpha: 1),
            .string: NSColor(srgbRed: 0.71, green: 0.54, blue: 0.0, alpha: 1),
            .number: NSColor(srgbRed: 0.83, green: 0.21, blue: 0.51, alpha: 1),
            .function: NSColor(srgbRed: 0.15, green: 0.55, blue: 0.82, alpha: 1),
            .type: NSColor(srgbRed: 0.15, green: 0.55, blue: 0.82, alpha: 1),
            .decorator: NSColor(srgbRed: 0.83, green: 0.21, blue: 0.51, alpha: 1),
            .oper: NSColor(srgbRed: 0.80, green: 0.29, blue: 0.09, alpha: 1),
        ]
    )

    /// All themes indexed to match the LaTeX editor theme array order.
    static let allThemes: [CodeSyntaxTheme] = [.kakuDark, .monokai, .dracula, .nord, .solarized]
}

enum CodeSyntaxHighlighter {
    private struct PatternRule {
        let kind: CodeTokenKind
        let pattern: String
        let options: NSRegularExpression.Options
        let captureGroup: Int?

        init(kind: CodeTokenKind, pattern: String, options: NSRegularExpression.Options = [], captureGroup: Int? = nil) {
            self.kind = kind
            self.pattern = pattern
            self.options = options
            self.captureGroup = captureGroup
        }
    }

    private static let pythonKeywords = [
        "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def",
        "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return",
        "try", "while", "with", "yield"
    ]

    private static let pythonTypes = [
        "False", "None", "True", "bool", "bytes", "dict", "float", "int", "list",
        "set", "str", "tuple"
    ]

    private static let rKeywords = [
        "if", "else", "for", "while", "repeat", "in", "next", "break", "function", "return"
    ]

    private static let rTypes = [
        "TRUE", "FALSE", "NULL", "NA", "NaN", "Inf", "T", "F"
    ]

    static func tokens(for text: String, language: CodeSyntaxLanguage) -> [CodeTokenSpan] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        guard fullRange.length > 0 else { return [] }

        let rules = rules(for: language)
        var accepted: [CodeTokenSpan] = []
        var occupied: [NSRange] = []

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, stop in
                guard let match else { return }
                let rawRange: NSRange
                if let captureGroup = rule.captureGroup {
                    guard captureGroup < match.numberOfRanges else { return }
                    rawRange = match.range(at: captureGroup)
                } else {
                    rawRange = match.range
                }
                guard rawRange.location != NSNotFound, rawRange.length > 0 else { return }
                guard !occupied.contains(where: { NSIntersectionRange($0, rawRange).length > 0 }) else { return }
                accepted.append(CodeTokenSpan(range: rawRange, kind: rule.kind))
                occupied.append(rawRange)
            }
        }

        return accepted.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length > $1.range.length
            }
            return $0.range.location < $1.range.location
        }
    }

    private static func rules(for language: CodeSyntaxLanguage) -> [PatternRule] {
        switch language {
        case .python:
            return [
                PatternRule(kind: .comment, pattern: #"(?m)#[^\n]*"#),
                PatternRule(kind: .string, pattern: #"(?s)(?:[rRuUbBfF]{0,3})\"\"\".*?\"\"\""#),
                PatternRule(kind: .string, pattern: #"(?s)(?:[rRuUbBfF]{0,3})'''.*?'''"#),
                PatternRule(kind: .string, pattern: #"(?:[rRuUbBfF]{0,3})\"(?:\\.|[^\"\\])*\""#),
                PatternRule(kind: .string, pattern: #"(?:[rRuUbBfF]{0,3})'(?:\\.|[^'\\])*'"#),
                PatternRule(kind: .decorator, pattern: #"(?m)^\s*@[A-Za-z_][A-Za-z0-9_\.]*"#),
                PatternRule(kind: .function, pattern: #"\bdef\s+([A-Za-z_][A-Za-z0-9_]*)"#, captureGroup: 1),
                PatternRule(kind: .type, pattern: #"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)"#, captureGroup: 1),
                PatternRule(kind: .keyword, pattern: wordBoundaryPattern(for: pythonKeywords)),
                PatternRule(kind: .type, pattern: wordBoundaryPattern(for: pythonTypes)),
                PatternRule(kind: .number, pattern: #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#),
                PatternRule(kind: .oper, pattern: #"(?x)(==|!=|<=|>=|:=|->|\+|-|\*|/|%|\*\*|//=|//=|//|=)"#),
            ]
        case .r:
            return [
                PatternRule(kind: .comment, pattern: #"(?m)#[^\n]*"#),
                PatternRule(kind: .string, pattern: #"\"(?:\\.|[^\"\\])*\""#),
                PatternRule(kind: .string, pattern: #"'(?:\\.|[^'\\])*'"#),
                PatternRule(kind: .function, pattern: #"\b([A-Za-z\.][A-Za-z0-9\._]*)\s*(?=\s*(?:<-|=)\s*function\b)"#, captureGroup: 1),
                PatternRule(kind: .keyword, pattern: wordBoundaryPattern(for: rKeywords)),
                PatternRule(kind: .type, pattern: wordBoundaryPattern(for: rTypes)),
                PatternRule(kind: .number, pattern: #"\b(?:\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#),
                PatternRule(kind: .oper, pattern: #"(?x)(<-|->|<<-|->>|:=|==|!=|<=|>=|\|>|%[^%]+%|=|\+|-|\*|/|\^)"#),
                PatternRule(kind: .function, pattern: #"\b([A-Za-z\.][A-Za-z0-9\._]*)\s*(?=\()"#, captureGroup: 1),
            ]
        }
    }

    private static func wordBoundaryPattern(for values: [String]) -> String {
        "\\b(?:\(values.joined(separator: "|")))\\b"
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
