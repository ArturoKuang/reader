import Foundation
import ReaderCore

public enum RecordAdapter {
    public static func wordId(for word: String) -> String {
        "w_" + WordStore.normalize(word)
    }

    public static func positionId(bookId: String, deviceId: String) -> String {
        "p_\(bookId)_\(deviceId)"
    }

    public static func highlightPayload(_ entry: HighlightEntry) -> [String: Any] {
        var object: [String: Any] = [
            "color": entry.color,
            "quote": entry.quote,
            "prefix": entry.prefix,
            "suffix": entry.suffix,
            "extras": extrasJSON(entry.extras),
        ]
        if let page = entry.page { object["page"] = page }
        if let cfi = entry.cfi { object["cfi"] = cfi }
        if let section = entry.section { object["section"] = section }
        if !entry.rects.isEmpty { object["rects"] = entry.rects }
        if let noteId = entry.noteID { object["noteId"] = noteId }
        return object
    }

    public static func notePayload(_ entry: NoteEntry, highlightId: String?) -> [String: Any] {
        var object: [String: Any] = [
            "quote": entry.quote,
            "prefix": entry.prefix,
            "suffix": entry.suffix,
            "ai": entry.ai,
            "scope": entry.scope,
            "body": entry.body,
            "extras": extrasJSON(entry.extras),
        ]
        if let page = entry.page { object["page"] = page }
        if let cfi = entry.cfi { object["cfi"] = cfi }
        if let section = entry.section { object["section"] = section }
        if let created = entry.created { object["created"] = created }
        if let updated = entry.updated { object["updated"] = updated }
        if let provider = entry.provider { object["provider"] = provider }
        if let highlightId { object["highlightId"] = highlightId }
        return object
    }

    public static func wordPayload(_ entry: WordEntry) -> [String: Any] {
        var object: [String: Any] = [
            "word": entry.word,
            "definition": entry.definition,
            "learned": entry.learned,
            "extras": extrasJSON(entry.extras),
        ]
        if let explanation = entry.explanation { object["explanation"] = explanation }
        if let provider = entry.explanationProvider { object["explanationProvider"] = provider }
        if let pronunciation = entry.pronunciation { object["pronunciation"] = pronunciation }
        if let part = entry.partOfSpeech { object["partOfSpeech"] = part }
        return object
    }

    public static func lookupPayload(_ entry: LookupEntry, wordId: String) -> [String: Any] {
        var object: [String: Any] = [
            "wordId": wordId,
            "quote": entry.quote,
            "prefix": entry.prefix,
            "suffix": entry.suffix,
            "sentence": entry.sentence,
            "date": entry.date,
            "extras": extrasJSON(entry.extras),
        ]
        if let page = entry.page { object["page"] = page }
        if let cfi = entry.cfi { object["cfi"] = cfi }
        if let section = entry.section { object["section"] = section }
        return object
    }

    /// EPUB positions are chapter-start only in v1: drop intra-chapter offsets and progression.
    public static func positionPayload(bookId: String, deviceId: String, isPDF: Bool, page: Int?, point: (x: Double, y: Double)?, cfi: String?) -> [String: Any] {
        let locator: [String: Any]
        if isPDF {
            var value: [String: Any] = ["format": "pdf", "page": page ?? 1]
            if let point {
                value["point"] = ["x": point.x, "y": point.y]
            }
            locator = value
        } else {
            locator = [
                "format": "epub",
                "cfi": EPUBPosition.chapterStart(cfi: cfi),
            ]
        }
        return [
            "bookId": bookId,
            "deviceId": deviceId,
            "locator": locator,
            "extras": [:],
        ]
    }

    public static func highlight(from payload: [String: Any], id: String) -> HighlightEntry {
        HighlightEntry(
            id: id,
            color: payload.int("color") ?? 1,
            page: payload.int("page"),
            cfi: payload.string("cfi"),
            quote: payload.string("quote") ?? "",
            prefix: payload.string("prefix") ?? "",
            suffix: payload.string("suffix") ?? "",
            section: payload.string("section"),
            rects: rects(from: payload["rects"]),
            noteID: payload.string("noteId"),
            extras: JSONSupport.extras(from: payload)
        )
    }

    public static func note(from payload: [String: Any], id: String) -> NoteEntry {
        NoteEntry(
            id: id,
            page: payload.int("page"),
            cfi: payload.string("cfi"),
            quote: payload.string("quote") ?? "",
            prefix: payload.string("prefix") ?? "",
            suffix: payload.string("suffix") ?? "",
            section: payload.string("section"),
            created: payload.string("created"),
            updated: payload.string("updated"),
            ai: payload.bool("ai") ?? false,
            provider: payload.string("provider"),
            scope: payload.string("scope") ?? "passage",
            body: payload.string("body") ?? "",
            extras: JSONSupport.extras(from: payload)
        )
    }

    public static func word(from payload: [String: Any], id: String, lookups: [LookupEntry] = []) -> WordEntry {
        WordEntry(
            id: id,
            word: payload.string("word") ?? "",
            definition: payload.string("definition") ?? "",
            explanation: payload.string("explanation"),
            explanationProvider: payload.string("explanationProvider"),
            pronunciation: payload.string("pronunciation"),
            partOfSpeech: payload.string("partOfSpeech"),
            learned: payload.bool("learned") ?? false,
            lookups: lookups,
            extras: JSONSupport.extras(from: payload)
        )
    }

    public static func lookup(from payload: [String: Any], id: String) -> LookupEntry {
        LookupEntry(
            id: id,
            page: payload.int("page"),
            cfi: payload.string("cfi"),
            section: payload.string("section"),
            quote: payload.string("quote") ?? "",
            prefix: payload.string("prefix") ?? "",
            suffix: payload.string("suffix") ?? "",
            sentence: payload.string("sentence") ?? "",
            date: payload.string("date") ?? "",
            extras: JSONSupport.extras(from: payload)
        )
    }

    public static func highlightColorName(_ color: Int) -> String {
        switch color {
        case 1: return "Yellow"
        case 2: return "Green"
        case 3: return "Blue"
        case 4: return "Pink"
        case 5: return "Purple"
        case 6: return "Orange"
        default: return "Highlight"
        }
    }

    public static func highlightColorHex(_ color: Int) -> String {
        let palette = ["F2C94C", "6FCF97", "56CCF2", "F28FB1", "BB6BD9", "F2994A"]
        guard HighlightPalette.isValid(color) else { return palette[0] }
        return palette[color - 1]
    }

    private static func extrasJSON(_ extras: [String: JSONValue]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: extras.map { ($0.key, JSONSupport.any(from: $0.value)) })
    }

    private static func rects(from any: Any?) -> [[Double]] {
        guard let rows = any as? [Any] else { return [] }
        return rows.compactMap { row in
            if let numbers = row as? [Double] { return numbers }
            if let numbers = row as? [NSNumber] { return numbers.map(\.doubleValue) }
            return nil
        }
    }
}

public enum EPUBPosition {
    /// v1: Mac sends and applies only the chapter (spine index) of a CFI.
    public static func chapterStart(cfi: String?) -> String {
        guard let cfi, let parsed = EPUBCFI(value: cfi), let spine = parsed.spineIndex else {
            return cfi ?? "epubcfi(/6/2!)"
        }
        let step = (spine + 1) * 2
        return "epubcfi(/6/\(step)!)"
    }

    public static func sameChapter(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let left = lhs.flatMap(EPUBCFI.init(value:)),
              let right = rhs.flatMap(EPUBCFI.init(value:)),
              let a = left.spineIndex, let b = right.spineIndex else { return false }
        return a == b
    }
}
