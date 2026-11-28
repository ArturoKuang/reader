import Foundation
import ReaderCore
import XCTest

final class UpdaterTests: XCTestCase {
    private let sampleSHA = String(repeating: "a", count: 64)

    private func makeManifest(
        schemaVersion: Int = 1,
        channel: String = "main",
        buildNumber: Int = 100,
        commitSHA: String = "1234567890abcdef1234567890abcdef12345678",
        artifactURL: String = "https://github.com/ArturoKuang/reader/releases/download/main-100/Reader-macos-arm64-1234567.zip",
        sha256: String? = nil
    ) -> UpdateManifest {
        UpdateManifest(
            schemaVersion: schemaVersion,
            channel: channel,
            version: "1.0-main.\(buildNumber)+\(String(commitSHA.prefix(7)))",
            buildNumber: buildNumber,
            commitSHA: commitSHA,
            publishedAt: "2026-11-28T04:00:00Z",
            releaseURL: "https://github.com/ArturoKuang/reader/releases/tag/main-\(buildNumber)",
            notes: "- Add auto updater (1234567)",
            artifacts: [
                "macos-app-arm64": UpdateArtifact(
                    url: artifactURL,
                    sha256: sha256 ?? sampleSHA,
                    size: 12_345_678
                ),
            ]
        )
    }

    func testManifestJSONRoundTrip() throws {
        let json = """
        {
          "schema_version": 1,
          "channel": "main",
          "version": "1.0-main.95+0aefd89",
          "build_number": 95,
          "commit_sha": "0aefd891234567890abcdef1234567890abcdef1",
          "published_at": "2026-11-28T04:00:00Z",
          "release_url": "https://github.com/ArturoKuang/reader/releases/tag/main-95",
          "notes": "- Fix toolbar",
          "artifacts": {
            "macos-app-arm64": {
              "url": "https://github.com/ArturoKuang/reader/releases/download/main-95/Reader-macos-arm64-0aefd89.zip",
              "sha256": "\(sampleSHA)",
              "size": 9876543
            }
          }
        }
        """
        let manifest = try UpdateEvaluator.parseManifest(Data(json.utf8))
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.buildNumber, 95)
        XCTAssertEqual(manifest.shortSHA, "0aefd89")
        XCTAssertEqual(manifest.artifacts["macos-app-arm64"]?.size, 9_876_543)
    }

    func testBuildInfoParsingForDevAndRelease() {
        let dev = AppBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ])
        XCTAssertTrue(dev.isDev)
        XCTAssertEqual(dev.channel, "dev")
        XCTAssertEqual(dev.shortSHA, "dev")
        XCTAssertEqual(dev.version, "1.0 (dev)")

        let release = AppBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "95",
            "ReaderChannel": "main",
            "ReaderCommitSHA": "0aefd891234567890abcdef",
            "ReaderBuiltAt": "2026-11-28T04:00:00Z",
            "ReaderVersion": "1.0-main.95+0aefd89",
        ])
        XCTAssertFalse(release.isDev)
        XCTAssertEqual(release.buildNumber, 95)
        XCTAssertEqual(release.shortSHA, "0aefd89")
        XCTAssertEqual(release.version, "1.0-main.95+0aefd89")
    }

    func testEvaluateNewerMainBuildIsAvailable() throws {
        let current = AppBuildInfo(
            version: "1.0-main.95+aaaaaaa",
            marketingVersion: "1.0",
            buildNumber: 95,
            channel: "main",
            commitSHA: "aaaaaaa111111111111111111111111111111111",
            builtAt: "2026-11-27T00:00:00Z"
        )
        let manifest = makeManifest(buildNumber: 100)
        let decision = try UpdateEvaluator.evaluate(
            manifest: manifest,
            current: current,
            artifactKey: "macos-app-arm64",
            allowDevUpgrade: false
        )
        guard case .available(let release) = decision else {
            return XCTFail("Expected update to be available")
        }
        XCTAssertEqual(release.buildNumber, 100)
        XCTAssertEqual(release.shortSHA, "1234567")
    }

    func testEvaluateSameBuildSameSHAIsUpToDate() throws {
        let sha = "1234567890abcdef1234567890abcdef12345678"
        let current = AppBuildInfo(
            version: "1.0-main.100+1234567",
            marketingVersion: "1.0",
            buildNumber: 100,
            channel: "main",
            commitSHA: sha,
            builtAt: "2026-11-28T00:00:00Z"
        )
        let decision = try UpdateEvaluator.evaluate(
            manifest: makeManifest(buildNumber: 100, commitSHA: sha),
            current: current,
            artifactKey: "macos-app-arm64",
            allowDevUpgrade: true
        )
        XCTAssertEqual(decision, .upToDate)
    }

    func testEvaluateOlderBuildIsUpToDate() throws {
        let current = AppBuildInfo(
            version: "1.0-main.105+bbbbbbb",
            marketingVersion: "1.0",
            buildNumber: 105,
            channel: "main",
            commitSHA: "bbbbbbb111111111111111111111111111111111",
            builtAt: "2026-11-28T00:00:00Z"
        )
        let decision = try UpdateEvaluator.evaluate(
            manifest: makeManifest(buildNumber: 100),
            current: current,
            artifactKey: "macos-app-arm64",
            allowDevUpgrade: true
        )
        XCTAssertEqual(decision, .upToDate)
    }

    func testEvaluateDevBuildRespectsAllowDevUpgradeFlag() throws {
        let dev = AppBuildInfo(infoDictionary: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"])
        let manifest = makeManifest(buildNumber: 100)

        let background = try UpdateEvaluator.evaluate(
            manifest: manifest,
            current: dev,
            artifactKey: "macos-app-arm64",
            allowDevUpgrade: false
        )
        XCTAssertEqual(background, .upToDate)

        let manual = try UpdateEvaluator.evaluate(
            manifest: manifest,
            current: dev,
            artifactKey: "macos-app-arm64",
            allowDevUpgrade: true
        )
        guard case .available(let release) = manual else {
            return XCTFail("Expected manual check on dev build to offer release")
        }
        XCTAssertEqual(release.buildNumber, 100)
    }

    func testEvaluateRejectsUntrustedURLAndBadSchemaAndBadDigest() {
        let dev = AppBuildInfo(infoDictionary: [:])

        XCTAssertThrowsError(try UpdateEvaluator.evaluate(
            manifest: makeManifest(schemaVersion: 2),
            current: dev,
            artifactKey: "macos-app-arm64",
            allowDevUpgrade: true
        )) { error in
            XCTAssertEqual(error as? UpdatePolicyError, .unsupportedSchemaVersion(2))
        }

        XCTAssertThrowsError(try UpdateEvaluator.evaluate(
            manifest: makeManifest(artifactURL: "https://evil.example.com/Reader.zip"),
            current: dev,
            artifactKey: "macos-app-arm64",
            allowDevUpgrade: true
        )) { error in
            XCTAssertEqual(error as? UpdatePolicyError, .invalidArtifactURL("https://evil.example.com/Reader.zip"))
        }

        XCTAssertThrowsError(try UpdateEvaluator.evaluate(
            manifest: makeManifest(sha256: "not-a-sha"),
            current: dev,
            artifactKey: "macos-app-arm64",
            allowDevUpgrade: true
        )) { error in
            XCTAssertEqual(error as? UpdatePolicyError, .invalidChecksumFormat("not-a-sha"))
        }
    }

    func testSwapScriptQuotesPathsWithSpacesAndApostrophes() {
        let script = UpdateSwapScript.build(
            parentPid: 4242,
            targetAppPath: "/Users/O'Brien/My Applications/Reader.app",
            stagedAppPath: "/tmp/stage/Reader.app",
            backupAppPath: "/Users/O'Brien/My Applications/.Reader.app.backup",
            launchUpdated: true
        )
        XCTAssertTrue(script.contains("PARENT_PID=4242"))
        XCTAssertTrue(script.contains("TARGET='/Users/O'\"'\"'Brien/My Applications/Reader.app'"))
        XCTAssertTrue(script.contains("LAUNCH=1"))
        XCTAssertTrue(script.contains("restore_backup"))
    }
}
