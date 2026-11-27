import Foundation
import ReaderSync

final class MockTransport: SyncTransporting, @unchecked Sendable {
    struct Call {
        var method: String
        var path: String
        var body: Data?
        var headers: [String: String]
    }

    var calls: [Call] = []
    /// Return (status, headers, body) for a request. Inspect `calls` after.
    var handler: (URLRequest) throws -> SyncHTTPResponse = { _ in
        SyncHTTPResponse(status: 404, headers: [:], data: Data())
    }

    func perform(_ request: URLRequest) async throws -> SyncHTTPResponse {
        var headers: [String: String] = [:]
        request.allHTTPHeaderFields?.forEach { headers[$0.key] = $0.value }
        calls.append(Call(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", body: request.httpBody, headers: headers))
        return try handler(request)
    }
}

func jsonResponse(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> SyncHTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return SyncHTTPResponse(status: status, headers: headers, data: data)
}

func makeEngine(transport: SyncTransporting, login: String? = "arturo@local") throws -> (SyncEngine, InMemoryCredentialStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-sync-tests-\(UUID().uuidString)", isDirectory: true)
    let credentials = InMemoryCredentialStore()
    let configuration = SyncClientConfiguration(
        baseURL: SyncClientConfiguration.loopbackTestURL,
        loopbackLogin: login,
        deviceName: "Test Mac",
        appVersion: "test"
    )
    let engine = try SyncEngine(directory: directory, configuration: configuration, credentials: credentials, transport: transport)
    return (engine, credentials, directory)
}
