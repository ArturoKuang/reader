import Foundation

public struct UpdateArtifact: Codable, Equatable, Sendable {
    public var url: String
    public var sha256: String
    public var size: UInt64

    public init(url: String, sha256: String, size: UInt64) {
        self.url = url
        self.sha256 = sha256
        self.size = size
    }
}

public struct UpdateManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var channel: String
    public var version: String
    public var buildNumber: Int
    public var commitSHA: String
    public var publishedAt: String
    public var releaseURL: String
    public var notes: String
    public var artifacts: [String: UpdateArtifact]

    public var shortSHA: String {
        String(commitSHA.prefix(7))
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case channel
        case version
        case buildNumber = "build_number"
        case commitSHA = "commit_sha"
        case publishedAt = "published_at"
        case releaseURL = "release_url"
        case notes
        case artifacts
    }

    public init(
        schemaVersion: Int,
        channel: String,
        version: String,
        buildNumber: Int,
        commitSHA: String,
        publishedAt: String,
        releaseURL: String,
        notes: String,
        artifacts: [String: UpdateArtifact]
    ) {
        self.schemaVersion = schemaVersion
        self.channel = channel
        self.version = version
        self.buildNumber = buildNumber
        self.commitSHA = commitSHA
        self.publishedAt = publishedAt
        self.releaseURL = releaseURL
        self.notes = notes
        self.artifacts = artifacts
    }
}

public struct AppBuildInfo: Equatable, Sendable {
    public var version: String
    public var marketingVersion: String
    public var buildNumber: Int
    public var channel: String
    public var commitSHA: String
    public var builtAt: String

    public var shortSHA: String {
        if commitSHA.isEmpty || commitSHA == "dev" {
            return "dev"
        }
        return String(commitSHA.prefix(7))
    }

    public var isDev: Bool {
        channel != "main" || commitSHA.isEmpty || commitSHA == "dev"
    }

    public init(
        version: String,
        marketingVersion: String,
        buildNumber: Int,
        channel: String,
        commitSHA: String,
        builtAt: String
    ) {
        self.version = version
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.channel = channel
        self.commitSHA = commitSHA
        self.builtAt = builtAt
    }

    public init(infoDictionary: [String: Any]) {
        let marketing = (infoDictionary["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMarketing = (marketing?.isEmpty == false ? marketing! : "1.0")
        let bundleVersion = (infoDictionary["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        let buildNumber = Int(bundleVersion) ?? 0
        let rawChannel = (infoDictionary["ReaderChannel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = (rawChannel?.isEmpty == false ? rawChannel! : "dev")
        let rawSHA = (infoDictionary["ReaderCommitSHA"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commitSHA = (rawSHA?.isEmpty == false ? rawSHA! : "dev")
        let builtAt = (infoDictionary["ReaderBuiltAt"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let explicitVersion = (infoDictionary["ReaderVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let version: String
        if let explicitVersion, !explicitVersion.isEmpty {
            version = explicitVersion
        } else if channel == "main", commitSHA != "dev" {
            version = "\(resolvedMarketing)-main.\(buildNumber)+\(String(commitSHA.prefix(7)))"
        } else {
            version = "\(resolvedMarketing) (dev)"
        }

        self.init(
            version: version,
            marketingVersion: resolvedMarketing,
            buildNumber: buildNumber,
            channel: channel,
            commitSHA: commitSHA,
            builtAt: builtAt
        )
    }
}

public struct UpdateRelease: Equatable, Sendable {
    public var channel: String
    public var version: String
    public var buildNumber: Int
    public var commitSHA: String
    public var shortSHA: String
    public var publishedAt: String
    public var releaseURL: String
    public var notes: String
    public var artifactKey: String
    public var artifact: UpdateArtifact

    public init(manifest: UpdateManifest, artifactKey: String, artifact: UpdateArtifact) {
        self.channel = manifest.channel
        self.version = manifest.version
        self.buildNumber = manifest.buildNumber
        self.commitSHA = manifest.commitSHA
        self.shortSHA = manifest.shortSHA
        self.publishedAt = manifest.publishedAt
        self.releaseURL = manifest.releaseURL
        self.notes = manifest.notes
        self.artifactKey = artifactKey
        self.artifact = artifact
    }
}

public enum UpdateCheckDecision: Equatable, Sendable {
    case upToDate
    case available(UpdateRelease)
}

public enum UpdatePolicyError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidManifest(String)
    case missingArtifact(String)
    case invalidArtifactURL(String)
    case invalidChecksumFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported update manifest schema version: \(version)."
        case .invalidManifest(let message):
            return "Invalid update manifest: \(message)"
        case .missingArtifact(let key):
            return "No release artifact available for this Mac (\(key))."
        case .invalidArtifactURL(let url):
            return "Update artifact URL is not trusted: \(url)"
        case .invalidChecksumFormat(let sha):
            return "Update manifest has an invalid SHA-256 digest: \(sha)"
        }
    }
}

public enum UpdateEvaluator {
    public static let defaultAllowedURLPrefix = "https://github.com/ArturoKuang/reader/releases/download/"

    public static func parseManifest(_ data: Data) throws -> UpdateManifest {
        do {
            return try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw UpdatePolicyError.invalidManifest(error.localizedDescription)
        }
    }

    public static func evaluate(
        manifest: UpdateManifest,
        current: AppBuildInfo,
        artifactKey: String,
        allowDevUpgrade: Bool,
        allowedURLPrefix: String? = defaultAllowedURLPrefix
    ) throws -> UpdateCheckDecision {
        guard manifest.schemaVersion == 1 else {
            throw UpdatePolicyError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard manifest.channel == "main" else {
            throw UpdatePolicyError.invalidManifest("expected channel 'main', got '\(manifest.channel)'")
        }
        guard manifest.buildNumber > 0 else {
            throw UpdatePolicyError.invalidManifest("build_number must be positive")
        }
        guard !manifest.commitSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UpdatePolicyError.invalidManifest("commit_sha is empty")
        }
        guard let artifact = manifest.artifacts[artifactKey] else {
            throw UpdatePolicyError.missingArtifact(artifactKey)
        }
        guard let url = URL(string: artifact.url), url.scheme?.lowercased() == "https" else {
            throw UpdatePolicyError.invalidArtifactURL(artifact.url)
        }
        if let allowedURLPrefix, !artifact.url.hasPrefix(allowedURLPrefix) {
            throw UpdatePolicyError.invalidArtifactURL(artifact.url)
        }
        let normalizedSHA = artifact.sha256.lowercased()
        let isValidHex = normalizedSHA.count == 64 && normalizedSHA.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
        guard isValidHex else {
            throw UpdatePolicyError.invalidChecksumFormat(artifact.sha256)
        }

        let normalizedArtifact = UpdateArtifact(url: artifact.url, sha256: normalizedSHA, size: artifact.size)
        let release = UpdateRelease(manifest: manifest, artifactKey: artifactKey, artifact: normalizedArtifact)

        if current.isDev {
            return allowDevUpgrade ? .available(release) : .upToDate
        }
        if manifest.buildNumber > current.buildNumber {
            return .available(release)
        }
        if manifest.buildNumber == current.buildNumber, manifest.commitSHA != current.commitSHA {
            return .available(release)
        }
        return .upToDate
    }
}

public enum UpdateSwapScript {
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func build(
        parentPid: Int32,
        targetAppPath: String,
        stagedAppPath: String,
        backupAppPath: String,
        launchUpdated: Bool = true
    ) -> String {
        let target = shellQuote(targetAppPath)
        let staged = shellQuote(stagedAppPath)
        let backup = shellQuote(backupAppPath)
        let launchFlag = launchUpdated ? "1" : "0"
        return """
        #!/bin/sh
        set -eu
        PARENT_PID=\(parentPid)
        TARGET=\(target)
        STAGED=\(staged)
        BACKUP=\(backup)
        LAUNCH=\(launchFlag)

        i=0
        while [ "$PARENT_PID" -gt 0 ] && kill -0 "$PARENT_PID" 2>/dev/null; do
            i=$((i + 1))
            if [ "$i" -ge 150 ]; then
                break
            fi
            sleep 0.1
        done

        restore_backup() {
            if [ -e "$BACKUP" ] && [ ! -e "$TARGET" ]; then
                mv "$BACKUP" "$TARGET" || true
            fi
            if [ "$LAUNCH" = "1" ] && [ -e "$TARGET" ]; then
                /usr/bin/open -n "$TARGET" || true
            fi
        }

        rm -rf "$BACKUP"
        if [ -e "$TARGET" ]; then
            mv "$TARGET" "$BACKUP"
        fi

        if ! mv "$STAGED" "$TARGET" 2>/dev/null; then
            if ! /usr/bin/ditto "$STAGED" "$TARGET"; then
                rm -rf "$TARGET"
                restore_backup
                exit 1
            fi
            rm -rf "$STAGED"
        fi

        if [ "$LAUNCH" = "1" ]; then
            if ! /usr/bin/open -n "$TARGET"; then
                rm -rf "$TARGET"
                restore_backup
                exit 1
            fi
        fi
        rm -rf "$BACKUP"
        """
    }
}
