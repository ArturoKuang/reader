import Foundation

/// A small TeX subset rendered to native MathML, with a spoken form for read-aloud.
public enum LaTeXMathRenderer {
    public struct RenderedMath: Equatable, Sendable {
        public var mathML: String
        public var spokenText: String
    }

    public static func render(_ tex: String, display: Bool) -> RenderedMath {
        var parser = Parser(c: Array(tex), display: display)
        var nodes: [Node] = []
        while parser.i < parser.c.count {
            nodes.append(parser.row(depth: 0))
            // A stray terminator is skipped so the rest still renders.
            if parser.i < parser.c.count { parser.i += 1 }
        }
        let all = join(nodes)
        let spoken = all.speech.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let math = "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"\(display ? "block" : "inline")\">\(all.xml)</math>"
        return RenderedMath(mathML: math, spokenText: spoken)
    }

    private struct Node {
        var xml: String
        var speech: String
        var largeOperator = false
    }

    private static func join(_ nodes: [Node]) -> Node {
        let xml = nodes.map(\.xml).joined()
        return Node(xml: nodes.count == 1 ? xml : "<mrow>\(xml)</mrow>", speech: nodes.map(\.speech).joined(separator: " "))
    }

    private static func tag(_ name: String, _ text: String, _ speech: String? = nil) -> Node {
        Node(xml: "<\(name)>\(MarkdownHTMLRenderer.escape(text))</\(name)>", speech: speech ?? text)
    }

    private static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    private static let operators: [String: (String, String)] = [
        "approx": ("≈", "approximately equals"), "neq": ("≠", "not equal to"), "ne": ("≠", "not equal to"),
        "le": ("≤", "less than or equal to"), "leq": ("≤", "less than or equal to"), "ge": ("≥", "greater than or equal to"),
        "geq": ("≥", "greater than or equal to"), "times": ("×", "times"), "cdot": ("⋅", "times"), "div": ("÷", "divided by"),
        "pm": ("±", "plus or minus"), "mp": ("∓", "minus or plus"), "to": ("→", "to"), "rightarrow": ("→", "to"),
        "leftarrow": ("←", "from"), "Rightarrow": ("⇒", "implies"), "Leftarrow": ("⇐", "is implied by"),
        "Leftrightarrow": ("⇔", "if and only if"), "iff": ("⇔", "if and only if"), "implies": ("⇒", "implies"),
        "mapsto": ("↦", "maps to"), "equiv": ("≡", "is equivalent to"), "sim": ("∼", "similar to"), "propto": ("∝", "proportional to"),
        "in": ("∈", "in"), "notin": ("∉", "not in"), "subset": ("⊂", "subset of"), "subseteq": ("⊆", "subset of or equal to"),
        "cup": ("∪", "union"), "cap": ("∩", "intersection"), "forall": ("∀", "for all"), "exists": ("∃", "there exists"),
        "partial": ("∂", "partial"), "nabla": ("∇", "nabla"), "ldots": ("…", "and so on"), "cdots": ("⋯", "and so on"),
        "dots": ("…", "and so on"), "circ": ("∘", "composed with"), "ast": ("∗", "star"), "ll": ("≪", "much less than"),
        "gg": ("≫", "much greater than"), "langle": ("⟨", ""), "rangle": ("⟩", ""), "mid": ("∣", "given"), "|": ("‖", ""),
        "{": ("{", ""), "}": ("}", ""),
    ]

    private static let large: [String: (String, String)] = [
        "sum": ("∑", "sum"), "prod": ("∏", "product"), "int": ("∫", "integral"), "oint": ("∮", "contour integral"),
        "bigcup": ("⋃", "union"), "bigcap": ("⋂", "intersection"), "lim": ("lim", "limit"), "max": ("max", "maximum"),
        "min": ("min", "minimum"), "sup": ("sup", "supremum"), "inf": ("inf", "infimum"),
    ]

    private static let functions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "log", "ln", "exp", "det", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "gcd"]
    private static let accents: [String: (String, String)] = [
        "hat": ("^", "hat"), "bar": ("¯", "bar"), "overline": ("¯", "bar"), "vec": ("→", "vector"),
        "tilde": ("~", "tilde"), "dot": ("˙", "dot"), "ddot": ("¨", "double dot"),
    ]

    private struct Parser {
        let c: [Character]
        let display: Bool
        var i = 0

        func peek(_ token: String) -> Bool {
            c[i...].starts(with: token)
        }

        /// Parses until `}`, `&`, `\\`, `\right`, `\end`, or the given bracket.
        mutating func row(depth: Int, until: Character? = nil) -> Node {
            var nodes: [Node] = []
            while i < c.count {
                if c[i] == "}" || c[i] == "&" || c[i] == until || peek("\\\\") || peek("\\right") && !peek("\\rightarrow") || peek("\\end{") { break }
                if c[i].isWhitespace { i += 1; continue }
                nodes.append(scripted(depth: depth))
            }
            return LaTeXMathRenderer.join(nodes)
        }

        mutating func scripted(depth: Int) -> Node {
            let base = (c[i] == "^" || c[i] == "_") ? Node(xml: "<mrow></mrow>", speech: "") : atom(depth: depth)
            var sub: Node?
            var sup: Node?
            while true {
                while i < c.count, c[i].isWhitespace { i += 1 }
                guard i < c.count else { break }
                if c[i] == "_", sub == nil { i += 1; sub = argument(depth: depth) }
                else if c[i] == "^", sup == nil { i += 1; sup = argument(depth: depth) }
                else if c[i] == "'", sup == nil { i += 1; sup = LaTeXMathRenderer.tag("mo", "′", "prime") }
                else { break }
            }
            if sub == nil && sup == nil { return base }
            let under = base.largeOperator && display
            let name: String
            if sub != nil && sup != nil { name = under ? "munderover" : "msubsup" }
            else if sub != nil { name = under ? "munder" : "msub" }
            else { name = under ? "mover" : "msup" }
            let xml = "<\(name)>\(base.xml)\(sub?.xml ?? "")\(sup?.xml ?? "")</\(name)>"
            var speech = base.speech
            if base.largeOperator {
                if let sub { speech += " from \(sub.speech)" }
                if let sup { speech += " to \(sup.speech)" }
                speech += " of"
            } else {
                if let sub { speech += " sub \(sub.speech)" }
                if let sup {
                    speech += sup.speech == "2" ? " squared" : sup.speech == "3" ? " cubed" : sup.speech == "prime" ? " prime" : " to the power \(sup.speech)"
                }
            }
            return Node(xml: xml, speech: speech)
        }

        /// A braced group, a command, or exactly one character.
        mutating func argument(depth: Int) -> Node {
            while i < c.count, c[i].isWhitespace { i += 1 }
            guard i < c.count, c[i] != "}" else { return Node(xml: "<mrow></mrow>", speech: "") }
            if c[i].isNumber { i += 1; return LaTeXMathRenderer.tag("mn", String(c[i - 1])) }
            return atom(depth: depth)
        }

        mutating func raw() -> String {
            while i < c.count, c[i].isWhitespace { i += 1 }
            guard i < c.count, c[i] == "{" else { return "" }
            i += 1
            var level = 1
            var text = ""
            while i < c.count {
                if c[i] == "{" { level += 1 }
                if c[i] == "}" { level -= 1; if level == 0 { i += 1; break } }
                text.append(c[i])
                i += 1
            }
            return text
        }

        mutating func command() -> String {
            i += 1
            guard i < c.count else { return "" }
            var name = ""
            while i < c.count, c[i].isASCII, c[i].isLetter { name.append(c[i]); i += 1 }
            if name.isEmpty { name = String(c[i]); i += 1 }
            return name
        }

        mutating func atom(depth: Int) -> Node {
            let ch = c[i]
            if depth > 40 { i += 1; return LaTeXMathRenderer.tag("mtext", String(ch)) }
            if ch == "{" {
                i += 1
                let inner = row(depth: depth + 1)
                if i < c.count, c[i] == "}" { i += 1 }
                return inner
            }
            if ch.isNumber {
                var number = ""
                while i < c.count, c[i].isNumber || (c[i] == "." && i + 1 < c.count && c[i + 1].isNumber) { number.append(c[i]); i += 1 }
                return LaTeXMathRenderer.tag("mn", number)
            }
            if ch != "\\" {
                i += 1
                if ch.isLetter { return LaTeXMathRenderer.tag("mi", String(ch)) }
                let words: [Character: String] = ["=": "equals", "+": "plus", "-": "minus", "<": "less than", ">": "greater than", "/": "over"]
                return LaTeXMathRenderer.tag("mo", ch == "-" ? "−" : String(ch), words[ch] ?? String(ch))
            }
            let name = command()
            if let letter = LaTeXMathRenderer.greek[name] { return LaTeXMathRenderer.tag("mi", letter, name) }
            if let op = LaTeXMathRenderer.operators[name] { return LaTeXMathRenderer.tag("mo", op.0, op.1) }
            if let op = LaTeXMathRenderer.large[name] {
                var node = LaTeXMathRenderer.tag("mo", op.0, op.1)
                node.largeOperator = true
                return node
            }
            if name == "infty" { return LaTeXMathRenderer.tag("mi", "∞", "infinity") }
            if LaTeXMathRenderer.functions.contains(name) { return LaTeXMathRenderer.tag("mi", name) }
            if let accent = LaTeXMathRenderer.accents[name] {
                let base = argument(depth: depth + 1)
                return Node(xml: "<mover accent=\"true\">\(base.xml)<mo>\(accent.0)</mo></mover>", speech: "\(base.speech) \(accent.1)")
            }
            switch name {
            case "frac", "dfrac", "tfrac":
                let top = argument(depth: depth + 1)
                let bottom = argument(depth: depth + 1)
                return Node(xml: "<mfrac>\(top.xml)\(bottom.xml)</mfrac>", speech: "\(top.speech) over \(bottom.speech)")
            case "sqrt":
                var index: Node?
                if i < c.count, c[i] == "[" {
                    i += 1
                    index = row(depth: depth + 1, until: "]")
                    if i < c.count { i += 1 }
                }
                let body = argument(depth: depth + 1)
                if let index { return Node(xml: "<mroot>\(body.xml)\(index.xml)</mroot>", speech: "root \(index.speech) of \(body.speech)") }
                return Node(xml: "<msqrt>\(body.xml)</msqrt>", speech: "square root of \(body.speech)")
            case "text", "textrm", "textbf", "mbox":
                let text = raw()
                let node = LaTeXMathRenderer.tag("mtext", text)
                return name == "textbf" ? Node(xml: "<mstyle mathvariant=\"bold\">\(node.xml)</mstyle>", speech: text) : node
            case "mathrm", "mathbf", "mathit", "mathbb", "mathcal", "operatorname":
                let text = raw()
                let variant = ["mathbf": "bold", "mathit": "italic", "mathbb": "double-struck", "mathcal": "script"][name] ?? "normal"
                return Node(xml: "<mi mathvariant=\"\(variant)\">\(MarkdownHTMLRenderer.escape(text))</mi>", speech: text)
            case "left":
                let open = delimiter()
                let inner = row(depth: depth + 1)
                var close = Node(xml: "", speech: "")
                if peek("\\right") { _ = command(); close = delimiter() }
                return Node(xml: "<mrow>\(open.xml)\(inner.xml)\(close.xml)</mrow>", speech: inner.speech)
            case "begin":
                return environment(raw(), depth: depth + 1)
            case ",", ":", ";", " ", "quad", "qquad":
                let width = name == "quad" ? "1em" : name == "qquad" ? "2em" : "0.2em"
                return Node(xml: "<mspace width=\"\(width)\"></mspace>", speech: "")
            case "!", "displaystyle", "limits":
                return Node(xml: "", speech: "")
            default:
                return LaTeXMathRenderer.tag("mtext", name.count == 1 ? name : "\\" + name, name)
            }
        }

        mutating func delimiter() -> Node {
            while i < c.count, c[i].isWhitespace { i += 1 }
            guard i < c.count else { return Node(xml: "", speech: "") }
            if c[i] == "." { i += 1; return Node(xml: "", speech: "") }
            return atom(depth: 0)
        }

        mutating func environment(_ name: String, depth: Int) -> Node {
            if name == "array" { _ = raw() }
            var rows: [[Node]] = [[]]
            while i < c.count {
                let cell = row(depth: depth)
                rows[rows.count - 1].append(cell)
                if i >= c.count { break }
                if c[i] == "&" { i += 1 }
                else if peek("\\\\") { i += 2; rows.append([]) }
                else if peek("\\end{") { _ = command(); _ = raw(); break }
                else { i += 1 }
            }
            rows.removeAll { $0.allSatisfy { $0.speech.isEmpty } }
            let body = rows.map { "<mtr>" + $0.map { "<mtd>\($0.xml)</mtd>" }.joined() + "</mtr>" }.joined()
            var xml = "<mtable>\(body)</mtable>"
            let fences = ["pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"), "vmatrix": ("|", "|"), "cases": ("{", "")][name]
            if let fences {
                xml = "<mrow><mo>\(fences.0)</mo>\(xml)" + (fences.1.isEmpty ? "" : "<mo>\(fences.1)</mo>") + "</mrow>"
            }
            let spoken = rows.map { $0.map(\.speech).joined(separator: ", ") }.joined(separator: "; ")
            return Node(xml: xml, speech: (name == "cases" ? "cases: " : "matrix: ") + spoken)
        }
    }
}
