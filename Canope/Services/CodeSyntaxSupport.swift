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
        backgroundColor: NSColor(hex: 0x272822),
        foregroundColor: NSColor(hex: 0xF8F8F2),
        selectionColor: NSColor(hex: 0x49483E),
        cursorColor: NSColor(hex: 0xF8F8F0),
        tokenColors: [
            .comment: NSColor(hex: 0x75715E),
            .keyword: NSColor(hex: 0xF92672),
            .string: NSColor(hex: 0xE6DB74),
            .number: NSColor(hex: 0xAE81FF),
            .function: NSColor(hex: 0xA6E22E),
            .type: NSColor(hex: 0x66D9EF),
            .decorator: NSColor(hex: 0xF92672),
            .oper: NSColor(hex: 0xF92672),
        ]
    )
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
