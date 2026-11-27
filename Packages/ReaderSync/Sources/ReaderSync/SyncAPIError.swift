import Foundation

public struct SyncAPIError: Error, Equatable, Sendable {
    public var status: Int
    public var code: String
    public var message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public var isDiskFull: Bool { code == "disk_full" || (status == 507 && code == "disk_full") }
    public var isQuotaExceeded: Bool { code == "quota_exceeded" }
    public var isUnauthorized: Bool { status == 401 || code == "unauthorized" }
    public var isNetwork: Bool { code == "network" }

    public static func parse(status: Int, data: Data) -> SyncAPIError {
        if let object = try? JSONSupport.object(from: data),
           let error = object["error"] as? [String: Any],
           let code = error.string("code") {
            return SyncAPIError(status: status, code: code, message: error.string("message") ?? code)
        }
        let fallback = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
        return SyncAPIError(status: status, code: status == 0 ? "network" : "http_\(status)", message: fallback)
    }

    public static func network(_ message: String) -> SyncAPIError {
        SyncAPIError(status: 0, code: "network", message: message)
    }
}
