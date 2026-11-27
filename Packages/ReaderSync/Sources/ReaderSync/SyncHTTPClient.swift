import Foundation

public struct SyncHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data

    public init(status: Int, headers: [String: String], data: Data) {
        self.status = status
        self.headers = headers
        self.data = data
    }

    public func header(_ name: String) -> String? {
        let target = name.lowercased()
        return headers.first { $0.key.lowercased() == target }?.value
    }

    public var uploadOffset: Int {
        if let value = header("Upload-Offset"), let number = Int(value) { return number }
        return 0
    }
}

public protocol SyncTransporting: Sendable {
    func perform(_ request: URLRequest) async throws -> SyncHTTPResponse
}

public struct URLSessionSyncTransport: SyncTransporting {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(_ request: URLRequest) async throws -> SyncHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncAPIError.network("missing HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String {
                    headers[key] = String(describing: value)
                }
            }
            return SyncHTTPResponse(status: http.statusCode, headers: headers, data: data)
        } catch let error as SyncAPIError {
            throw error
        } catch {
            throw SyncAPIError.network(error.localizedDescription)
        }
    }
}

public struct SyncClientConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var loopbackLogin: String?
    public var userAgent: String
    public var deviceName: String
    public var appVersion: String

    public static let productionBaseURL = URL(string: "https://arturos-mac-mini.tail8dc761.ts.net/v1/reader")!
    public static let loopbackTestURL = URL(string: "http://127.0.0.1:8789/v1/reader")!

    public init(
        baseURL: URL = SyncClientConfiguration.productionBaseURL,
        loopbackLogin: String? = nil,
        userAgent: String = "Reader-macOS/1.0",
        deviceName: String = "Mac",
        appVersion: String = "1.0"
    ) {
        self.baseURL = baseURL
        self.loopbackLogin = loopbackLogin
        self.userAgent = userAgent
        self.deviceName = deviceName
        self.appVersion = appVersion
    }

    public var hostCaption: String { baseURL.host ?? baseURL.absoluteString }

    public var isLoopback: Bool {
        guard let host = baseURL.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

public final class SyncHTTPClient: @unchecked Sendable {
    public var configuration: SyncClientConfiguration
    public var credential: String?
    public var transport: SyncTransporting

    public init(configuration: SyncClientConfiguration, credential: String? = nil, transport: SyncTransporting = URLSessionSyncTransport()) {
        self.configuration = configuration
        self.credential = credential
        self.transport = transport
    }

    public func get(path: String, query: [String: String] = [:], authorized: Bool = true) async throws -> SyncHTTPResponse {
        try await send(method: "GET", path: path, query: query, authorized: authorized)
    }

    public func head(path: String, authorized: Bool = true) async throws -> SyncHTTPResponse {
        try await send(method: "HEAD", path: path, authorized: authorized)
    }

    public func delete(path: String, authorized: Bool = true) async throws -> SyncHTTPResponse {
        try await send(method: "DELETE", path: path, authorized: authorized)
    }

    public func post(path: String, body: [String: Any]?, authorized: Bool = true, extraHeaders: [String: String] = [:]) async throws -> SyncHTTPResponse {
        let data = try body.map { try JSONSupport.data($0) }
        return try await send(method: "POST", path: path, body: data, authorized: authorized, extraHeaders: extraHeaders)
    }

    public func put(path: String, data: Data, headers: [String: String], authorized: Bool = true) async throws -> SyncHTTPResponse {
        try await send(method: "PUT", path: path, body: data, authorized: authorized, extraHeaders: headers, contentType: "application/octet-stream")
    }

    public func send(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Data? = nil,
        authorized: Bool = true,
        extraHeaders: [String: String] = [:],
        contentType: String = "application/json"
    ) async throws -> SyncHTTPResponse {
        let url = try url(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if authorized, let credential, !credential.isEmpty {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        } else if let login = configuration.loopbackLogin, !login.isEmpty, shouldSendLoopbackLogin(authorized: authorized) {
            request.setValue(login, forHTTPHeaderField: "Tailscale-User-Login")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return try await transport.perform(request)
    }

    public func requireOK(_ response: SyncHTTPResponse, allowed: Set<Int> = [200]) throws -> SyncHTTPResponse {
        if allowed.contains(response.status) { return response }
        throw SyncAPIError.parse(status: response.status, data: response.data)
    }

    private func shouldSendLoopbackLogin(authorized: Bool) -> Bool {
        // Only for first-time admin calls on a loopback test server. Production
        // HTTPS goes through tailscale serve, which injects the identity itself.
        configuration.isLoopback && configuration.loopbackLogin != nil
    }

    private func url(path: String, query: [String: String]) throws -> URL {
        let base = configuration.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? path : "/" + path
        var components = URLComponents(string: base + suffix)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "invalid URL")
        }
        return url
    }
}
