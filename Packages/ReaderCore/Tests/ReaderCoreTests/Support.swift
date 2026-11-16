import Foundation
import ReaderCore
import XCTest

final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

func sync<T>(_ work: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await work()) }
        catch { box.result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result!.get()
}

func temporaryDirectory() throws -> String {
    let path = Paths.join(FileManager.default.temporaryDirectory.path, "reader-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

final class MemoryFileSystem: FileSystem {
    enum Node {
        case file(Data)
        case directory
        case link(String)
    }

    private var nodes: [String: Node] = ["/": .directory]
    var readOnly: Set<String> = []

    func exists(_ path: String) -> Bool {
        resolve(path) != nil
    }

    func isDirectory(_ path: String) -> Bool {
        if case .directory = resolve(path) { return true }
        return false
    }

    func isWritable(_ path: String) -> Bool {
        !readOnly.contains(Paths.normalize(path))
    }

    func list(_ path: String) throws -> [String] {
        let directory = Paths.normalize(path)
        guard case .directory = nodes[directory] else { throw ReaderFailure("Not a directory") }
        let prefix = directory == "/" ? "/" : directory + "/"
        var names: Set<String> = []
        for key in nodes.keys where key != directory && key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            if let name = rest.split(separator: "/").first {
                names.insert(String(name))
            }
        }
        return names.sorted()
    }

    func read(_ path: String) throws -> Data {
        guard let node = resolve(path) else { throw ReaderFailure("Missing \(path)") }
        if case .file(let data) = node { return data }
        throw ReaderFailure("Not a file \(path)")
    }

    func write(_ path: String, _ data: Data) throws {
        let normalized = Paths.normalize(path)
        let parent = Paths.parent(normalized)
        if readOnly.contains(parent) { throw ReaderFailure("unwritable") }
        guard case .directory = nodes[parent] else { throw ReaderFailure("No parent \(parent)") }
        nodes[normalized] = .file(data)
    }

    func createDirectory(_ path: String) throws {
        let normalized = Paths.normalize(path)
        var current = ""
        for part in normalized.split(separator: "/") {
            let parent = current.isEmpty ? "/" : current
            current = parent == "/" ? "/" + part : parent + "/" + part
            if let existing = nodes[current] {
                guard case .directory = existing else { throw ReaderFailure("File in the way") }
                continue
            }
            if readOnly.contains(parent) { throw ReaderFailure("unwritable") }
            nodes[current] = .directory
        }
    }

    func remove(_ path: String) throws {
        let normalized = Paths.normalize(path)
        nodes.keys.filter { $0 == normalized || $0.hasPrefix(normalized + "/") }.forEach { nodes[$0] = nil }
    }

    func move(_ from: String, _ to: String) throws {
        let source = Paths.normalize(from)
        let destination = Paths.normalize(to)
        guard nodes[source] != nil else { throw ReaderFailure("Missing \(from)") }
        let keys = nodes.keys.filter { $0 == source || $0.hasPrefix(source + "/") }
        var moving: [String: Node] = [:]
        for key in keys {
            moving[key] = nodes[key]
            nodes[key] = nil
        }
        for (key, node) in moving {
            let suffix = String(key.dropFirst(source.count))
            nodes[destination + suffix] = node
        }
    }

    func symlink(target: String, linkAt: String) throws {
        nodes[Paths.normalize(linkAt)] = .link(target)
    }

    private func resolve(_ path: String) -> Node? {
        let normalized = Paths.normalize(path)
        if case .link(let target) = nodes[normalized] {
            return nodes[Paths.normalize(target)]
        }
        return nodes[normalized]
    }
}

final class FakeTransport: HTTPTransport {
    var request: HTTPRequest?
    var body: String
    init(body: String) { self.body = body }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        self.request = request
        return HTTPResponse(status: 200, body: Data(body.utf8))
    }
}

final class FakeRunner: CommandRunning {
    var invocation: CLIInvocation?
    func cancel() {}
    func run(_ invocation: CLIInvocation, timeout: TimeInterval, onStdout: @escaping (String) -> Void) throws -> CommandResult {
        self.invocation = invocation
        let stdout = "{\"type\":\"result\",\"result\":\"Because they share the same food.\",\"is_error\":false}\n"
        onStdout(stdout)
        return CommandResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false, cancelled: false)
    }
}
