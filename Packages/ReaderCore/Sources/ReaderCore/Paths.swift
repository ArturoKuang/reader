import Foundation

public enum Paths {
    public static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        if parts.isEmpty { return absolute ? "/" : "." }
        return (absolute ? "/" : "") + parts.joined(separator: "/")
    }

    public static func parent(_ path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" || normalized == "." { return normalized }
        guard let slash = normalized.lastIndex(of: "/") else { return "." }
        let parent = String(normalized[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func name(_ path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" { return "" }
        guard let slash = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: slash)...])
    }

    public static func stem(_ path: String) -> String {
        let file = name(path)
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return file }
        return String(file[..<dot])
    }

    public static func join(_ directory: String, _ child: String) -> String {
        if directory == "/" { return "/" + child }
        if directory == "." { return child }
        return directory + "/" + child
    }

    /// A notes or vocabulary path typed by a person. It must stay inside the book folder.
    public static func isSafeRelative(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return false }
        if trimmed.contains(":") || trimmed.contains("\\") || trimmed.contains("\0") { return false }
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." { return false }
        }
        return true
    }
}

public struct ReaderFailure: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum IDs {
    public static func make(_ prefix: String) -> String {
        prefix + "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
