import Foundation

public enum WikiLinkResolution: Equatable, Sendable {
    case localHeading(anchorID: String)
    case file(path: String, headingAnchor: String?)
    case notFound(target: String)
}

public enum MarkdownWikiLinkResolver {
    private static let extensions = ["md", "markdown", "mdown"]
    private static let searchLimit = 5_000

    public static func resolve(target: String, heading: String?, currentFilePath: String, vaultRoot: String?, fs: FileSystem) -> WikiLinkResolution {
        let anchor = heading.flatMap { $0.isEmpty || $0.hasPrefix("^") ? nil : MarkdownParser.slug($0) }
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            if let anchor { return .localHeading(anchorID: anchor) }
            return .notFound(target: target)
        }
        let missing = WikiLinkResolution.notFound(target: target)
        if name.hasPrefix("/") || name.hasPrefix("~") { return missing }
        let lower = name.lowercased()
        var candidates = extensions.map { "\(name).\($0)" }
        // A target with an extension may name an asset; "v1.2" is still a note.
        if lower.contains(".") { candidates.insert(name, at: 0) }
        let current = Paths.parent(currentFilePath)
        let roots = [current] + (vaultRoot.map { [Paths.normalize($0)] } ?? [])
        for base in roots {
            for candidate in candidates {
                let path = Paths.normalize(Paths.join(base, candidate))
                if roots.contains(where: { isInside(path, $0) }), fs.exists(path), !fs.isDirectory(path) {
                    return .file(path: path, headingAnchor: anchor)
                }
            }
        }
        guard let vaultRoot else { return missing }
        let wanted = candidates.map { "/" + $0.lowercased() }
        var queue = [Paths.normalize(vaultRoot)]
        var visited = 0
        while !queue.isEmpty, visited < searchLimit {
            let directory = queue.removeFirst()
            for entry in (try? fs.list(directory))?.sorted() ?? [] where !entry.hasPrefix(".") {
                visited += 1
                let path = Paths.join(directory, entry)
                if fs.isDirectory(path) {
                    queue.append(path)
                } else if wanted.contains(where: { path.lowercased().hasSuffix($0) }) {
                    return .file(path: path, headingAnchor: anchor)
                }
            }
        }
        return missing
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        let root = Paths.normalize(root)
        return root == "/" || Paths.normalize(path).hasPrefix(root + "/")
    }
}
