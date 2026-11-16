import Foundation

public protocol FileSystem {
    func exists(_ path: String) -> Bool
    func isDirectory(_ path: String) -> Bool
    func isWritable(_ path: String) -> Bool
    func list(_ path: String) throws -> [String]
    func read(_ path: String) throws -> Data
    func write(_ path: String, _ data: Data) throws
    func createDirectory(_ path: String) throws
    func remove(_ path: String) throws
    func move(_ from: String, _ to: String) throws
    func symlink(target: String, linkAt: String) throws
}

public struct LocalFileSystem: FileSystem {
    public init() {}
    private let files = FileManager.default

    public func exists(_ path: String) -> Bool {
        files.fileExists(atPath: path)
    }

    public func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return files.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    public func isWritable(_ path: String) -> Bool {
        files.isWritableFile(atPath: path)
    }

    public func list(_ path: String) throws -> [String] {
        try files.contentsOfDirectory(atPath: path).sorted()
    }

    public func read(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func write(_ path: String, _ data: Data) throws {
        let url = URL(fileURLWithPath: path)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".reader-\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        if files.fileExists(atPath: path) {
            try files.removeItem(at: url)
        }
        try files.moveItem(at: temporary, to: url)
    }

    public func createDirectory(_ path: String) throws {
        try files.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func remove(_ path: String) throws {
        if exists(path) {
            try files.removeItem(atPath: path)
        }
    }

    public func move(_ from: String, _ to: String) throws {
        if exists(to) {
            try files.removeItem(atPath: to)
        }
        try files.moveItem(atPath: from, toPath: to)
    }

    public func symlink(target: String, linkAt: String) throws {
        if exists(linkAt) {
            try files.removeItem(atPath: linkAt)
        }
        try files.createSymbolicLink(atPath: linkAt, withDestinationPath: target)
    }
}

extension FileSystem {
    public func readString(_ path: String) throws -> String {
        let data = try read(path)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ReaderFailure("\(path) is not UTF-8")
        }
        return string
    }

    public func writeString(_ path: String, _ string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw ReaderFailure("Could not encode \(path)")
        }
        try write(path, data)
    }
}
