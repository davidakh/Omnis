import SwiftUI

/// Turns a model's Markdown answer into one attributed string for `StreamingText`: lists,
/// headings, quotes and code blocks as styled lines, inline Markdown (bold, italics, code,
/// links) as usual, and LaTeX math (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`) as readable Unicode.
///
/// Kept to a single string (rather than a view per block) so the answer still streams in
/// with the blur reveal.
enum AnswerFormatting {
    static func attributed(_ markdown: String, size: CGFloat) -> AttributedString {
        var output = AttributedString()
        var lines: [AttributedString] = []
        var codeLines: [String]?
        var mathLines: [String]?
        var mathCloser = "$$"
        var lastWasBlank = false

        func emit(_ line: AttributedString) {
            lines.append(line)
            lastWasBlank = false
        }

        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Inside a code block: as is, until the closing fence.
            if var code = codeLines {
                if trimmed.hasPrefix("```") {
                    for line in code { emit(codeLine(line, size: size)) }
                    codeLines = nil
                } else {
                    code.append(raw)
                    codeLines = code
                }
                continue
            }
            // Inside display math: collect until the closer.
            if var math = mathLines {
                if let range = trimmed.range(of: mathCloser) {
                    math.append(String(trimmed[..<range.lowerBound]))
                    emit(displayMath(math.joined(separator: " "), size: size))
                    mathLines = nil
                } else {
                    math.append(trimmed)
                    mathLines = math
                }
                continue
            }

            if trimmed.isEmpty {
                // Paragraph breaks stay, but runs of blank lines collapse to one.
                if !lastWasBlank, !lines.isEmpty {
                    lines.append(AttributedString())
                    lastWasBlank = true
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                codeLines = []
                continue
            }
            if let (opener, closer) = [("$$", "$$"), ("\\[", "\\]")].first(where: { trimmed.hasPrefix($0.0) }) {
                let rest = String(trimmed.dropFirst(opener.count))
                if let range = rest.range(of: closer) {
                    emit(displayMath(String(rest[..<range.lowerBound]), size: size))
                } else {
                    mathLines = [rest]
                    mathCloser = closer
                }
                continue
            }
            emit(blockLine(raw, trimmed: trimmed, size: size))
        }
        // Still streaming: show what's there of an unfinished block.
        if let code = codeLines { for line in code { emit(codeLine(line, size: size)) } }
        if let math = mathLines { emit(displayMath(math.joined(separator: " "), size: size)) }

        while lines.last?.characters.isEmpty == true { lines.removeLast() }
        for (index, line) in lines.enumerated() {
            if index > 0 { output.append(AttributedString("\n")) }
            output.append(line)
        }
        return output
    }

    // MARK: Blocks

    private static func blockLine(_ raw: String, trimmed: String, size: CGFloat) -> AttributedString {
        let level = leadingIndent(raw) / 2
        let indent = String(repeating: "    ", count: level)

        // Heading: "# Title".
        if let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
            let depth = match.1.count
            var line = inline(String(match.2), size: size)
            let headingSize = size + (depth == 1 ? 4 : depth == 2 ? 2 : 0)
            line.font = .system(size: headingSize, weight: .semibold)
            return line
        }
        // Horizontal rule: "---", "***", "___".
        if trimmed.wholeMatch(of: /([-*_])(\s*\1){2,}/) != nil {
            var rule = AttributedString("———")
            rule.foregroundColor = .white.opacity(0.3)
            return rule
        }
        // Bullet: "- item", "* item", "+ item".
        if let match = trimmed.firstMatch(of: /^[-*+]\s+(.*)$/) {
            var line = AttributedString(indent + (level == 0 ? "•  " : "◦  "))
            line.append(inline(String(match.1), size: size))
            return line
        }
        // Numbered: "1. item", "1) item".
        if let match = trimmed.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
            var line = AttributedString(indent + "\(match.1).  ")
            line.append(inline(String(match.2), size: size))
            return line
        }
        // Quote: "> text".
        if let match = trimmed.firstMatch(of: /^>\s?(.*)$/) {
            var bar = AttributedString("▎ ")
            bar.foregroundColor = .white.opacity(0.35)
            var text = inline(String(match.1), size: size)
            text.foregroundColor = .white.opacity(0.75)
            bar.append(text)
            return bar
        }
        return inline(trimmed, size: size)
    }

    private static func codeLine(_ line: String, size: CGFloat) -> AttributedString {
        var code = AttributedString(line.isEmpty ? " " : line)
        code.font = .system(size: size - 2, design: .monospaced)
        code.foregroundColor = .white.opacity(0.85)
        return code
    }

    private static func displayMath(_ latex: String, size: CGFloat) -> AttributedString {
        var math = AttributedString("    " + LaTeXText.unicode(latex))
        math.font = mathFont(size: size)
        return math
    }

    private static func mathFont(size: CGFloat) -> Font {
        .system(size: size, design: .serif).italic()
    }

    private static func leadingIndent(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }

    // MARK: Inline

    /// Inline Markdown, with inline math pulled out first so its underscores and asterisks
    /// aren't read as emphasis.
    private static func inline(_ text: String, size: CGFloat) -> AttributedString {
        var output = AttributedString()
        for segment in inlineSegments(text) {
            switch segment {
            case .text(let text):
                let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                output.append((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
            case .math(let latex):
                var math = AttributedString(LaTeXText.unicode(latex))
                math.font = mathFont(size: size)
                output.append(math)
            }
        }
        return output
    }

    private enum Segment {
        case text(String)
        case math(String)
    }

    /// Splits out `\(…\)` and `$…$`. A `$` only opens math when the next character isn't a
    /// space, and only closes it when the previous character isn't a space and the next isn't
    /// a digit, so prices like "$5 and $10" stay text.
    private static func inlineSegments(_ text: String) -> [Segment] {
        let characters = Array(text)
        var segments: [Segment] = []
        var buffer = ""
        var index = 0

        func flush() {
            if !buffer.isEmpty { segments.append(.text(buffer)); buffer = "" }
        }

        while index < characters.count {
            let character = characters[index]
            // \( … \)
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "(" {
                if let close = find(["\\", ")"], in: characters, from: index + 2) {
                    flush()
                    segments.append(.math(String(characters[(index + 2)..<close])))
                    index = close + 2
                    continue
                }
            }
            // $ … $
            if character == "$", index + 1 < characters.count, characters[index + 1] != " ", characters[index + 1] != "$",
               index == 0 || characters[index - 1] != "\\" {
                // Math closes at the next unescaped `$` or not at all: if that one can't close
                // it (as in "$5 and $10"), this `$` is just text.
                var close = index + 1
                while close < characters.count, characters[close] != "$" || characters[close - 1] == "\\" {
                    close += 1
                }
                var found: Int?
                if close < characters.count, characters[close - 1] != " ",
                   close + 1 >= characters.count || !characters[close + 1].isNumber {
                    found = close
                }
                if let found, found > index + 1 {
                    flush()
                    segments.append(.math(String(characters[(index + 1)..<found])))
                    index = found + 1
                    continue
                }
            }
            buffer.append(character)
            index += 1
        }
        flush()
        return segments
    }

    private static func find(_ pattern: [Character], in characters: [Character], from start: Int) -> Int? {
        guard characters.count >= pattern.count else { return nil }
        var index = start
        while index + pattern.count <= characters.count {
            if Array(characters[index..<(index + pattern.count)]) == pattern { return index }
            index += 1
        }
        return nil
    }
}

/// Renders LaTeX math as plain Unicode text: superscripts and subscripts, fractions as a/b,
/// roots as √, and commands as their symbols. Unknown commands are kept by name.
enum LaTeXText {
    static func unicode(_ latex: String) -> String {
        let characters = Array(latex)
        var index = 0
        var result = convert(characters, &index, inGroup: false)
        result = result.replacingOccurrences(of: "-", with: "−")
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func convert(_ c: [Character], _ i: inout Int, inGroup: Bool) -> String {
        var out = ""
        while i < c.count {
            let character = c[i]
            switch character {
            case "}":
                i += 1
                if inGroup { return out }
            case "{":
                i += 1
                out += convert(c, &i, inGroup: true)
            case "\\":
                out += command(c, &i)
            case "^":
                i += 1
                out += script(argument(c, &i), map: superscripts, marker: "^")
            case "_":
                i += 1
                out += script(argument(c, &i), map: subscripts, marker: "_")
            case "&", "~":
                i += 1
                out += " "
            default:
                i += 1
                out.append(character)
            }
        }
        return out
    }

    /// A `\command` at `i`, with its arguments.
    private static func command(_ c: [Character], _ i: inout Int) -> String {
        i += 1  // the backslash
        guard i < c.count else { return "" }
        // Single-character commands: escapes and spacing.
        if !c[i].isLetter {
            let symbol = c[i]
            i += 1
            switch symbol {
            case ",", ":", ";", " ": return " "
            case "!": return ""
            case "\\": return "; "
            case "{", "}", "%", "$", "#", "&", "_": return String(symbol)
            default: return String(symbol)
            }
        }
        var name = ""
        while i < c.count, c[i].isLetter { name.append(c[i]); i += 1 }

        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            let numerator = argument(c, &i)
            let denominator = argument(c, &i)
            return grouped(numerator) + "/" + grouped(denominator)
        case "sqrt":
            var degree = ""
            if i < c.count, c[i] == "[" {
                i += 1
                while i < c.count, c[i] != "]" { degree.append(c[i]); i += 1 }
                i += 1
            }
            let root = degree == "3" ? "∛" : degree == "4" ? "∜" : script(degree, map: superscripts, marker: "") + "√"
            return root + grouped(argument(c, &i))
        case "text", "textrm", "textbf", "textit", "mathrm", "mathbf", "mathit", "mathsf", "mathcal",
             "mathbb", "boldsymbol", "operatorname", "mbox":
            return argument(c, &i)
        case "left", "right", "big", "Big", "bigg", "Bigg", "displaystyle", "limits":
            // A following "." is an invisible delimiter.
            if i < c.count, c[i] == "." { i += 1 }
            return ""
        case "quad", "qquad": return " "
        default:
            return symbols[name] ?? name
        }
    }

    /// The next argument: a `{group}`, a command, or a single character.
    private static func argument(_ c: [Character], _ i: inout Int) -> String {
        while i < c.count, c[i] == " " { i += 1 }
        guard i < c.count else { return "" }
        if c[i] == "{" {
            i += 1
            return convert(c, &i, inGroup: true)
        }
        if c[i] == "\\" { return command(c, &i) }
        let character = c[i]
        i += 1
        return String(character)
    }

    /// Wraps a fraction's part in parentheses when it's more than one term.
    private static func grouped(_ part: String) -> String {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        let isSimple = trimmed.count <= 1 || trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." }
        return isSimple ? trimmed : "(\(trimmed))"
    }

    /// Superscript or subscript characters when every character has one, else `^(…)`.
    private static func script(_ text: String, map: [Character: Character], marker: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if marker == "^", trimmed == "∘" || trimmed == "°" { return "°" }
        guard !trimmed.isEmpty else { return "" }
        let mapped = trimmed.compactMap { map[$0] }
        if mapped.count == trimmed.count { return String(mapped) }
        return marker + (trimmed.count == 1 ? trimmed : "(\(trimmed))")
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ",
        "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
        "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ"
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
    ]

    private static let symbols: [String: String] = [
        // Operators and relations
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆", "circ": "∘",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈", "sim": "∼",
        "simeq": "≃", "cong": "≅", "equiv": "≡", "propto": "∝", "ll": "≪", "gg": "≫",
        "lt": "<", "gt": ">", "mid": "∣", "parallel": "∥", "perp": "⊥",
        // Arrows
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "implies": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⇔",
        "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
        // Sets and logic
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
        "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨", "setminus": "∖",
        // Big operators and calculus
        "sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮", "partial": "∂", "nabla": "∇",
        "infty": "∞", "lim": "lim", "log": "log", "ln": "ln", "exp": "exp", "sin": "sin", "cos": "cos",
        "tan": "tan", "sec": "sec", "csc": "csc", "cot": "cot", "arcsin": "arcsin", "arccos": "arccos",
        "arctan": "arctan", "max": "max", "min": "min", "det": "det",
        // Geometry and misc
        "angle": "∠", "triangle": "△", "degree": "°", "prime": "′", "ldots": "…", "cdots": "⋯", "dots": "…",
        "vdots": "⋮", "therefore": "∴", "because": "∵", "langle": "⟨", "rangle": "⟩", "lfloor": "⌊",
        "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ",
        "aleph": "ℵ", "checkmark": "✓",
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ",
        "nu": "ν", "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω"
    ]
}
