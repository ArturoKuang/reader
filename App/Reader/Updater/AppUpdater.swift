import AppKit
import Combine
import CryptoKit
import Foundation
import ReaderCore

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease)
    case downloading(UpdateRelease, Double?)
    case installing(UpdateRelease)
    case error(String)

    var availableRelease: UpdateRelease? {
        switch self {
        case .available(let release), .downloading(let release, _), .installing(let release):
            return release
        default:
            return nil
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }
}

enum AppUpdaterError: LocalizedError {
    case invalidManifestURL(String)
    case httpStatus(Int, String)
    case invalidPublicKey
    case invalidSignatureFormat
    case signatureVerificationFailed
    case checksumMismatch(expected: String, actual: String)
    case notAppBundle(URL)
    case directoryNotWritable(URL)
    case extractionFailed(String)
    case invalidBundle(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifestURL(let url):
            return "Invalid update manifest URL: \(url)"
        case .httpStatus(let code, let url):
            if code == 404 {
                return "No published release found yet on main (\(url))."
            }
            return "Update server returned HTTP \(code) for \(url)."
        case .invalidPublicKey:
            return "Embedded update signing public key is invalid."
        case .invalidSignatureFormat:
            return "Update signature file is malformed."
        case .signatureVerificationFailed:
            return "Update manifest signature verification failed."
        case .checksumMismatch(let expected, let actual):
            return "Downloaded archive checksum mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .notAppBundle(let url):
            return "Self-update requires running Reader.app (current bundle: \(url.path))."
        case .directoryNotWritable(let dir):
            return "Cannot write to \(dir.path). Move Reader.app to ~/Applications to enable in-app updates."
        case .extractionFailed(let message):
            return "Failed to extract update archive: \(message)"
        case .invalidBundle(let message):
            return "Downloaded app bundle is invalid: \(message)"
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (Double?) -> Void
    private var lastReport: TimeInterval = -.infinity
    private var continuation: CheckedContinuation<URL, Error>?
    private var movedFileURL: URL?
    private var moveError: Error?

    init(destination: URL, onProgress: @escaping (Double?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func start(request: URLRequest) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: request)
            task.resume()
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let complete = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard now - lastReport >= 0.1 || complete else { return }
        lastReport = now
        let fraction: Double? = totalBytesExpectedToWrite > 0
            ? min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            : nil
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            moveError = AppUpdaterError.httpStatus(http.statusCode, downloadTask.originalRequest?.url?.absoluteString ?? "")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            movedFileURL = destination
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let moveError {
            continuation.resume(throwing: moveError)
        } else if let movedFileURL {
            continuation.resume(returning: movedFileURL)
        } else {
            continuation.resume(throwing: AppUpdaterError.invalidBundle("Download did not produce an archive file."))
        }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    static let autoCheckDefaultsKey = "reader.autoCheckUpdates"
    static let skippedBuildDefaultsKey = "reader.skippedUpdateBuild"
    static let defaultManifestURL = "https://github.com/ArturoKuang/reader/releases/download/main-latest/manifest.json"
    static let defaultPublicKeyBase64 = "vu0lKVXUkj0Mwdq+MxQSlshl9UFc+vMZwrFbMj5SLd8="
    static let checkIntervalSeconds: TimeInterval = 4 * 60 * 60
    static let initialCheckDelaySeconds: TimeInterval = 30
    static let expectedBundleID = "com.reader.Reader"

    static var currentArtifactKey: String {
        #if arch(arm64)
        return "macos-app-arm64"
        #else
        return "macos-app-x86_64"
        #endif
    }

    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var currentBuild: AppBuildInfo
    @Published var autoCheckEnabled: Bool {
        didSet {
            defaults.set(autoCheckEnabled, forKey: Self.autoCheckDefaultsKey)
            rescheduleBackgroundChecks()
        }
    }

    private let defaults: UserDefaults
    private let manifestURLString: String
    private let publicKeyBase64: String
    private var initialTimer: Timer?
    private var periodicTimer: Timer?

    init(
        defaults: UserDefaults = .standard,
        manifestURL: String = AppUpdater.defaultManifestURL,
        publicKeyBase64: String = AppUpdater.defaultPublicKeyBase64,
        startBackgroundChecks: Bool = true
    ) {
        self.defaults = defaults
        self.manifestURLString = manifestURL
        self.publicKeyBase64 = publicKeyBase64
        self.currentBuild = AppBuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
        if defaults.object(forKey: Self.autoCheckDefaultsKey) == nil {
            self.autoCheckEnabled = true
        } else {
            self.autoCheckEnabled = defaults.bool(forKey: Self.autoCheckDefaultsKey)
        }

        Self.cleanupStaleArtifacts()
        if startBackgroundChecks {
            rescheduleBackgroundChecks()
        }
    }

    deinit {
        initialTimer?.invalidate()
        periodicTimer?.invalidate()
    }

    func checkForUpdates(manual: Bool) {
        guard !state.isBusy else { return }
        if manual {
            defaults.removeObject(forKey: Self.skippedBuildDefaultsKey)
            state = .checking
        }
        let manifestURLString = self.manifestURLString
        let publicKeyBase64 = self.publicKeyBase64
        let currentBuild = self.currentBuild
        let artifactKey = Self.currentArtifactKey
        let skippedBuild = manual ? 0 : defaults.integer(forKey: Self.skippedBuildDefaultsKey)

        Task.detached(priority: .utility) { [weak self] in
            let result: Result<UpdateCheckDecision, Error>
            do {
                let manifestData = try await Self.fetchData(from: manifestURLString)
                let signatureData = try await Self.fetchData(from: manifestURLString + ".sig")
                try Self.verifySignature(
                    manifestData: manifestData,
                    signatureFileData: signatureData,
                    publicKeyBase64: publicKeyBase64
                )
                let manifest = try UpdateEvaluator.parseManifest(manifestData)
                let decision = try UpdateEvaluator.evaluate(
                    manifest: manifest,
                    current: currentBuild,
                    artifactKey: artifactKey,
                    allowDevUpgrade: manual
                )
                result = .success(decision)
            } catch {
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(.upToDate):
                    if manual {
                        self.state = .upToDate
                    }
                case .success(.available(let release)):
                    if !manual && skippedBuild == release.buildNumber {
                        return
                    }
                    self.state = .available(release)
                case .failure(let error):
                    if manual {
                        self.state = .error(error.localizedDescription)
                    }
                }
            }
        }
    }

    func skipRelease(_ release: UpdateRelease) {
        defaults.set(release.buildNumber, forKey: Self.skippedBuildDefaultsKey)
        state = .idle
    }

    func installUpdate(
        _ release: UpdateRelease,
        bundleURL: URL = Bundle.main.bundleURL,
        beforeExit: @escaping @MainActor () -> Void,
        terminate: @escaping @MainActor () -> Void
    ) {
        guard !state.isBusy else { return }
        guard bundleURL.pathExtension == "app" else {
            state = .error(AppUpdaterError.notAppBundle(bundleURL).localizedDescription)
            return
        }
        let parentDir = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            state = .error(AppUpdaterError.directoryNotWritable(parentDir).localizedDescription)
            return
        }

        state = .downloading(release, nil)
        let cacheRoot = Self.updatesCacheDirectory()
        let pid = ProcessInfo.processInfo.processIdentifier

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let stageDir = cacheRoot.appendingPathComponent(
                    "\(release.shortSHA)-\(UUID().uuidString.prefix(8))",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
                let archiveURL = stageDir.appendingPathComponent("Reader.zip")
                guard let downloadURL = URL(string: release.artifact.url) else {
                    throw UpdatePolicyError.invalidArtifactURL(release.artifact.url)
                }

                var request = URLRequest(url: downloadURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Reader/\(release.version)", forHTTPHeaderField: "User-Agent")

                let delegate = DownloadDelegate(destination: archiveURL) { fraction in
                    Task { @MainActor [weak self] in
                        self?.state = .downloading(release, fraction)
                    }
                }
                _ = try await delegate.start(request: request)

                await MainActor.run { [weak self] in
                    self?.state = .installing(release)
                }

                let actualSHA = try Self.sha256Hex(ofFileAt: archiveURL)
                guard actualSHA == release.artifact.sha256.lowercased() else {
                    throw AppUpdaterError.checksumMismatch(expected: release.artifact.sha256, actual: actualSHA)
                }

                let extractDir = stageDir.appendingPathComponent("extracted", isDirectory: true)
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
                try Self.extractZip(archiveURL, to: extractDir)

                let stagedApp = extractDir.appendingPathComponent("Reader.app", isDirectory: true)
                Self.clearQuarantine(at: stagedApp)
                try Self.validateAppBundle(at: stagedApp, expectedBundleID: Self.expectedBundleID)

                let backupApp = parentDir.appendingPathComponent(".\(bundleURL.lastPathComponent).backup")
                let scriptURL = stageDir.appendingPathComponent("swap-and-relaunch.sh")
                let script = UpdateSwapScript.build(
                    parentPid: pid,
                    targetAppPath: bundleURL.path,
                    stagedAppPath: stagedApp.path,
                    backupAppPath: backupApp.path,
                    launchUpdated: true
                )
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    beforeExit()
                    do {
                        try Self.spawnDetachedScript(scriptURL)
                        terminate()
                    } catch {
                        self.state = .error(error.localizedDescription)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.state = .error(error.localizedDescription)
                }
            }
        }
    }

    private func rescheduleBackgroundChecks() {
        initialTimer?.invalidate()
        initialTimer = nil
        periodicTimer?.invalidate()
        periodicTimer = nil
        guard autoCheckEnabled else { return }

        let initial = Timer(timeInterval: Self.initialCheckDelaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForUpdates(manual: false)
            }
        }
        RunLoop.main.add(initial, forMode: .common)
        initialTimer = initial

        let periodic = Timer(timeInterval: Self.checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForUpdates(manual: false)
            }
        }
        RunLoop.main.add(periodic, forMode: .common)
        periodicTimer = periodic
    }

    nonisolated static func fetchData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw AppUpdaterError.invalidManifestURL(urlString)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppUpdaterError.httpStatus(http.statusCode, urlString)
        }
        return data
    }

    nonisolated static func verifySignature(
        manifestData: Data,
        signatureFileData: Data,
        publicKeyBase64: String
    ) throws {
        guard let keyData = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw AppUpdaterError.invalidPublicKey
        }
        guard let signatureText = String(data: signatureFileData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let signatureBytes = Data(base64Encoded: signatureText) else {
            throw AppUpdaterError.invalidSignatureFormat
        }
        guard publicKey.isValidSignature(signatureBytes, for: manifestData) else {
            throw AppUpdaterError.signatureVerificationFailed
        }
    }

    nonisolated static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func updatesCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(expectedBundleID, isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
    }

    nonisolated static func cleanupStaleArtifacts(bundleURL: URL = Bundle.main.bundleURL) {
        let fm = FileManager.default
        if bundleURL.pathExtension == "app" {
            let backup = bundleURL.deletingLastPathComponent()
                .appendingPathComponent(".\(bundleURL.lastPathComponent).backup")
            try? fm.removeItem(at: backup)
        }
        let cacheDir = updatesCacheDirectory()
        if let entries = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) {
            let cutoff = Date().addingTimeInterval(-60 * 60)
            for entry in entries {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < cutoff {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }

    nonisolated static func extractZip(_ archiveURL: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destination.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ditto exited \(process.terminationStatus)"
            throw AppUpdaterError.extractionFailed(msg)
        }
    }

    nonisolated static func clearQuarantine(at appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    nonisolated static func validateAppBundle(
        at appURL: URL,
        expectedBundleID: String = AppUpdater.expectedBundleID,
        verifyCodesign: Bool = true
    ) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppUpdaterError.invalidBundle("Contents/Info.plist is missing or unreadable")
        }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, bundleID == expectedBundleID else {
            throw AppUpdaterError.invalidBundle("unexpected CFBundleIdentifier")
        }
        guard let executableName = plist["CFBundleExecutable"] as? String, !executableName.isEmpty else {
            throw AppUpdaterError.invalidBundle("CFBundleExecutable is missing")
        }
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AppUpdaterError.invalidBundle("executable \(executableName) is missing or not executable")
        }
        if verifyCodesign {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--deep", appURL.path]
            let stderr = Pipe()
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let msg = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "codesign verify failed"
                throw AppUpdaterError.invalidBundle(msg)
            }
        }
    }

    private nonisolated static func spawnDetachedScript(_ scriptURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/sh \(UpdateSwapScript.shellQuote(scriptURL.path)) >/dev/null 2>&1 &"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
}
