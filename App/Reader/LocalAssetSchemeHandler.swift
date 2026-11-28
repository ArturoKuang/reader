import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves `reader-local://file/<absolute path>`, only for files inside the allowed folders.
final class LocalAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "reader-local"
    private let roots: () -> [String]

    init(roots: @escaping () -> [String]) {
        self.roots = roots
    }

    static func url(for file: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = file.path
        return components.url
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let file = allowedFile(url), let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    /// Requests are answered synchronously, so there is nothing to cancel.
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    /// Symlinks are resolved on both sides before the containment check.
    private func allowedFile(_ url: URL) -> URL? {
        guard url.host == "file", !url.path.isEmpty else { return nil }
        let file = URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
        let inside = roots().contains { root in
            let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            return file.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        var isDirectory: ObjCBool = false
        guard inside, FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return file
    }
}
