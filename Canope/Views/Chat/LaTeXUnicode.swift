import Foundation

// MARK: - LaTeX to Unicode Converter

enum LaTeXUnicode {
    private static let greekLetters: [String: String] = [
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ",
        "\\epsilon": "ε", "\\zeta": "ζ", "\\eta": "η", "\\theta": "θ",
        "\\iota": "ι", "\\kappa": "κ", "\\lambda": "λ", "\\mu": "μ",
        "\\nu": "ν", "\\xi": "ξ", "\\pi": "π", "\\rho": "ρ",
        "\\sigma": "σ", "\\tau": "τ", "\\upsilon": "υ", "\\phi": "φ",
        "\\chi": "χ", "\\psi": "ψ", "\\omega": "ω",
        "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ",
        "\\Sigma": "Σ", "\\Phi": "Φ", "\\Psi": "Ψ", "\\Omega": "Ω",
        "\\infty": "∞", "\\partial": "∂", "\\nabla": "∇",
        "\\pm": "±", "\\times": "×", "\\div": "÷", "\\cdot": "·",
        "\\leq": "≤", "\\geq": "≥", "\\neq": "≠", "\\approx": "≈",
        "\\sim": "∼", "\\propto": "∝", "\\sum": "Σ", "\\prod": "Π",
        "\\sqrt": "√", "\\degree": "°", "\\circ": "°",
    ]

    private static let subscriptDigits: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
    ]

    private static let superscriptDigits: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "-": "⁻", "+": "⁺", "n": "ⁿ",
    ]

    static func convert(_ text: String) -> String {
        var result = text

        // Remove $ delimiters
        result = result.replacingOccurrences(of: "$", with: "")

        // Greek letters and symbols (longer names first to avoid partial matches)
        let sorted = greekLetters.sorted { $0.key.count > $1.key.count }
        for (latex, unicode) in sorted {
            result = result.replacingOccurrences(of: latex, with: unicode)
        }

        // Subscripts: _{...} or _x
        result = replacePattern(in: result, pattern: #"_\{([^}]+)\}"#) { match in
            String(match.map { subscriptDigits[$0] ?? $0 })
        }
        result = replacePattern(in: result, pattern: #"_([0-9a-z])"#) { match in
            String(match.map { subscriptDigits[$0] ?? $0 })
        }

        // Superscripts: ^{...} or ^x
        result = replacePattern(in: result, pattern: #"\^\{([^}]+)\}"#) { match in
            String(match.map { superscriptDigits[$0] ?? $0 })
        }
        result = replacePattern(in: result, pattern: #"\^([0-9n+-])"#) { match in
            String(match.map { superscriptDigits[$0] ?? $0 })
        }

        // \text{...} → just the text
        result = replacePattern(in: result, pattern: #"\\text\{([^}]+)\}"#) { $0 }
        // \mathrm{...} → just the text
        result = replacePattern(in: result, pattern: #"\\mathrm\{([^}]+)\}"#) { $0 }
        // \frac{a}{b} → a/b
        result = result.replacingOccurrences(
            of: #"\\frac\{([^}]+)\}\{([^}]+)\}"#,
            with: "$1/$2",
            options: .regularExpression
        )

        // Clean up remaining backslash commands
        result = result.replacingOccurrences(of: "\\,", with: " ")
        result = result.replacingOccurrences(of: "\\;", with: " ")
        result = result.replacingOccurrences(of: "\\!", with: "")
        result = result.replacingOccurrences(of: "\\quad", with: "  ")

        return result
    }

    private static func replacePattern(in text: String, pattern: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: result)
            else { continue }
            let captured = String(result[captureRange])
            result.replaceSubrange(fullRange, with: transform(captured))
        }
        return result
    }
}

