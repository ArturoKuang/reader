import Foundation

/// QR v2 pairing payload: `readersync://pair?v=2&url=<base>&token=<t>&server=<serverId>`.
public struct PairingQR: Equatable, Sendable {
    public var version: Int
    public var url: URL
    public var token: String
    public var serverId: String

    public init(version: Int = 2, url: URL, token: String, serverId: String) {
        self.version = version
        self.url = url
        self.token = token
        self.serverId = serverId
    }

    public var payload: String {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "server", value: serverId),
        ]
        var components = URLComponents()
        components.scheme = "readersync"
        components.host = "pair"
        components.queryItems = items
        // URLComponents encodes query values; keep `:` and `/` in `url` unescaped per spec.
        guard var built = components.string else {
            return "readersync://pair?v=2&url=\(Self.encodeURL(url.absoluteString))&token=\(Self.encodeToken(token))&server=\(Self.encodeToken(serverId))"
        }
        if let range = built.range(of: "url=") {
            let after = built[range.upperBound...]
            let end = after.firstIndex(of: "&") ?? built.endIndex
            let raw = String(built[range.upperBound..<end])
            let fixed = Self.encodeURL(url.absoluteString)
            if raw != fixed {
                built.replaceSubrange(range.upperBound..<end, with: fixed)
            }
        }
        return built
    }

    public static func parse(_ raw: String) throws -> PairingQR {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "not a pairing QR")
        }
        guard components.scheme?.lowercased() == "readersync",
              (components.host?.lowercased() == "pair" || components.path == "pair" || components.path == "//pair") else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "not a readersync pairing QR")
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value, !value.isEmpty else { return nil }
            return (item.name, value)
        })
        guard let versionText = items["v"], let version = Int(versionText) else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "pairing QR is missing v")
        }
        if version == 1 {
            throw SyncAPIError(status: 0, code: "bad_request", message: "clients reject v=1 pairing QR codes")
        }
        guard version == 2 else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "unsupported pairing QR version \(version)")
        }
        guard let urlText = items["url"], let url = URL(string: urlText), url.scheme != nil, url.host != nil else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "pairing QR is missing a valid url")
        }
        guard let token = items["token"], !token.isEmpty else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "pairing QR is missing token")
        }
        guard let serverId = items["server"], !serverId.isEmpty else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "pairing QR is missing server")
        }
        return PairingQR(version: version, url: url, token: token, serverId: serverId)
    }

    public static func make(baseURL: URL, token: String, serverId: String) -> PairingQR {
        PairingQR(url: baseURL, token: token, serverId: serverId)
    }

    /// Percent-encode characters outside RFC 3986 unreserved plus `:` and `/`.
    public static func encodeURL(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~:/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public static func encodeToken(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
