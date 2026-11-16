import Foundation

/// A practical EPUB CFI subset. The raw string is preserved so an anchor round-trips
/// even when it uses assertions or paths Reader does not interpret. Navigation uses
/// the spine index (EPUB's even-numbered itemref step) and the character offsets.
public struct EPUBCFI: Equatable, Sendable {
    public var value: String
    public var spineIndex: Int?
    public var startOffset: Int?
    public var endOffset: Int?

    public init?(value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("epubcfi("), trimmed.hasSuffix(")") else { return nil }
        self.value = trimmed
        let inner = String(trimmed.dropFirst("epubcfi(".count).dropLast())
        let package = inner.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? inner
        let steps = package.split(separator: "/").compactMap { part -> Int? in
            let digits = part.prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        if steps.count >= 2, steps[0] == 6, steps[1].isMultiple(of: 2), steps[1] >= 2 {
            spineIndex = steps[1] / 2 - 1
        } else {
            spineIndex = nil
        }
        let offsets = Self.offsets(in: inner)
        startOffset = offsets.first
        endOffset = offsets.dropFirst().first
    }

    public static func make(spineIndex: Int, start: Int, end: Int, intraPath: String = "/4") -> EPUBCFI {
        let step = (spineIndex + 1) * 2
        let path = intraPath.hasPrefix("/") ? intraPath : "/" + intraPath
        let value = "epubcfi(/6/\(step)!\(path),/1:\(start),/1:\(end))"
        return EPUBCFI(value: value)!
    }

    private static func offsets(in inner: String) -> [Int] {
        var found: [Int] = []
        var index = inner.startIndex
        while index < inner.endIndex {
            if inner[index] == ":" {
                var cursor = inner.index(after: index)
                var digits = ""
                while cursor < inner.endIndex, inner[cursor].isNumber {
                    digits.append(inner[cursor])
                    cursor = inner.index(after: cursor)
                }
                if let number = Int(digits) { found.append(number) }
                index = cursor
            } else {
                index = inner.index(after: index)
            }
        }
        return found
    }
}
