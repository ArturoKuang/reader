import Foundation
import ReaderCore
import XCTest

// MARK: - Deterministic Seeded PRNG & Formal Test Configuration

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func nextBool(probabilityTrue: Double = 0.5) -> Bool {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return unit < probabilityTrue
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[nextInt(in: 0...(items.count - 1))]
    }
}

private enum FormalConfig {
    static let defaultSeed: UInt64 = 0x5245_4144_4552_0001
    static let defaultCases: Int = 200

    static var seed: UInt64 {
        guard let raw = ProcessInfo.processInfo.environment["FORMAL_SEED"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return defaultSeed
        }
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            return UInt64(raw.dropFirst(2), radix: 16) ?? defaultSeed
        }
        return UInt64(raw) ?? defaultSeed
    }

    static var cases: Int {
        guard let raw = ProcessInfo.processInfo.environment["FORMAL_CASES"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = Int(raw), parsed > 0 else {
            return defaultCases
        }
        return parsed
    }

    static func seedTag(_ seed: UInt64, caseIndex: Int? = nil) -> String {
        let hex = String(format: "0x%016llx", seed)
        if let caseIndex {
            return "[FORMAL_SEED=\(hex) case=\(caseIndex)]"
        }
        return "[FORMAL_SEED=\(hex)]"
    }
}

// MARK: - Generators

private extension SplitMix64 {
    mutating func randomSafeSlice(minLen: Int = 0, maxLen: Int = 60, allowNewlines: Bool = true) -> String {
        let atoms = allowNewlines
            ? ["alpha", "beta", "gamma", " ", "\t", "\n", "- item", "# Heading", "> quote", "**bold**", "café", "λόγος", "漢字", "—", "<!-- note -->", "x"]
            : ["alpha", "beta", "gamma", " ", "\t", "- item", "**bold**", "café", "λόγος", "漢字", "—", "x"]
        let count = nextInt(in: minLen...maxLen)
        var out = ""
        for _ in 0..<count {
            out += pick(atoms)
        }
        // Guarantee sentinel tokens never appear inside generated user slices or block bodies.
        return out
            .replacingOccurrences(of: "<!-- reader:begin id=", with: "<!-- user:begin ")
            .replacingOccurrences(of: "<!-- reader:end -->", with: "<!-- user:end -->")
    }

    mutating func randomBlockId() -> String {
        let prefixes = ["h", "n", "w", "blk", "item"]
        let suffix = nextInt(in: 0...9999)
        return "\(pick(prefixes))_\(suffix)"
    }

    mutating func randomBlockBody() -> String {
        let lineCount = nextInt(in: 0...4)
        if lineCount == 0 { return "" }
        let lines = (0..<lineCount).map { _ in randomSafeSlice(minLen: 0, maxLen: 6, allowNewlines: false) }
        return lines.joined(separator: "\n")
    }

    mutating func randomHex(length: Int, allowUppercase: Bool = false) -> String {
        let lower = Array("0123456789abcdef")
        let mixed = Array("0123456789abcdefABCDEF")
        let alphabet = allowUppercase ? mixed : lower
        return String((0..<length).map { _ in pick(alphabet) })
    }

    mutating func randomNonWhitespaceASCIIWord(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in pick(chars) })
    }
}

// MARK: - Independent Reference Oracles

private enum UpdatePolicyOracle {
    static func evaluate(
        manifest: UpdateManifest,
        current: AppBuildInfo,
        artifactKey: String,
        allowDevUpgrade: Bool,
        allowedURLPrefix: String?
    ) -> Result<UpdateCheckDecision, UpdatePolicyError> {
        if manifest.schemaVersion != 1 {
            return .failure(.unsupportedSchemaVersion(manifest.schemaVersion))
        }
        if manifest.channel != "main" {
            return .failure(.invalidManifest("channel"))
        }
        if manifest.buildNumber <= 0 {
            return .failure(.invalidManifest("buildNumber"))
        }
        if manifest.commitSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.invalidManifest("commitSHA"))
        }
        guard let artifact = manifest.artifacts[artifactKey] else {
            return .failure(.missingArtifact(artifactKey))
        }
        guard let url = URL(string: artifact.url), url.scheme?.lowercased() == "https" else {
            return .failure(.invalidArtifactURL(artifact.url))
        }
        if let prefix = allowedURLPrefix, !artifact.url.hasPrefix(prefix) {
            return .failure(.invalidArtifactURL(artifact.url))
        }
        let lowerSHA = artifact.sha256.lowercased()
        let hexOK = lowerSHA.count == 64 && lowerSHA.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
        if !hexOK {
            return .failure(.invalidChecksumFormat(artifact.sha256))
        }
        let normalizedArtifact = UpdateArtifact(url: artifact.url, sha256: lowerSHA, size: artifact.size)
        let release = UpdateRelease(manifest: manifest, artifactKey: artifactKey, artifact: normalizedArtifact)

        let isDev = current.channel != "main" || current.commitSHA.isEmpty || current.commitSHA == "dev"
        if isDev {
            return .success(allowDevUpgrade ? .available(release) : .upToDate)
        }
        if manifest.buildNumber > current.buildNumber {
            return .success(.available(release))
        }
        if manifest.buildNumber == current.buildNumber && manifest.commitSHA != current.commitSHA {
            return .success(.available(release))
        }
        return .success(.upToDate)
    }
}

private enum OwnedBlocksInvariant {
    static func nonWhitespaceUserBytes(_ text: String) -> String {
        let userText = OwnedBlocks.parse(text)
            .filter { $0.kind == .user }
            .map(\.raw)
            .joined()
        return String(userText.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    static func userPieces(_ text: String) -> [String] {
        OwnedBlocks.parse(text)
            .filter { $0.kind == .user }
            .map(\.raw)
    }

    static func checkUserPreservation(initialUserSlices: [String], document: String) -> String? {
        let expectedCompact = String(initialUserSlices.joined().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        let actualCompact = nonWhitespaceUserBytes(document)
        if actualCompact != expectedCompact {
            return "non-whitespace user text drifted: expected \(expectedCompact.debugDescription), got \(actualCompact.debugDescription)"
        }
        let fullUserText = OwnedBlocks.parse(document).filter { $0.kind == .user }.map(\.raw).joined()
        var searchStart = fullUserText.startIndex
        for slice in initialUserSlices where !slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let core = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let found = fullUserText.range(of: core, range: searchStart..<fullUserText.endIndex) else {
                return "user slice \(core.debugDescription) missing or out of order in user text \(fullUserText.debugDescription)"
            }
            searchStart = found.upperBound
        }
        return nil
    }
}

// MARK: - Formal Property Tests

final class FormalPropertyTests: XCTestCase {

    // MARK: Oracle / Checker Self-Test

    func testInvariantCheckerSelfTestCatchesCorruptedUserText() {
        let userSlices = ["Outline A\n", "\t- user bullet\n"]
        let goodDoc = OwnedBlocks.upsert(userSlices.joined(), id: "n1", body: "reader note")
        XCTAssertNil(OwnedBlocksInvariant.checkUserPreservation(initialUserSlices: userSlices, document: goodDoc))

        let corrupted = goodDoc.replacingOccurrences(of: "user bullet", with: "clobbered")
        XCTAssertNotNil(
            OwnedBlocksInvariant.checkUserPreservation(initialUserSlices: userSlices, document: corrupted),
            "Invariant checker must detect corrupted user text"
        )
    }

    // MARK: OwnedBlocks Formal Properties

    func testOwnedBlocksRenderParseRoundTrip() {
        let seed = FormalConfig.seed ^ 0x01
        var rng = SplitMix64(seed: seed)
        let cases = FormalConfig.cases

        for i in 0..<cases {
            let id = rng.randomBlockId()
            let body = rng.randomBlockBody()
            let rendered = OwnedBlocks.render(id: id, body: body)
            let pieces = OwnedBlocks.parse(rendered)

            XCTAssertEqual(
                pieces.count, 1,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) render/parse piece count mismatch for id=\(id) body=\(body.debugDescription)"
            )
            XCTAssertEqual(
                pieces.first?.kind, .owned(id: id),
                "\(FormalConfig.seedTag(seed, caseIndex: i)) parsed kind mismatch"
            )
            XCTAssertEqual(
                pieces.first?.body, body,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) body round-trip failed for id=\(id) body=\(body.debugDescription)"
            )
            XCTAssertEqual(
                pieces.first?.raw, rendered,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) raw round-trip failed"
            )
            XCTAssertEqual(
                OwnedBlocks.body(id: id, in: rendered), body,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) OwnedBlocks.body mismatch"
            )
        }
    }

    func testOwnedBlocksRenderParsePreservesTrailingCarriageReturn() {
        // Explicit Unicode/CRLF boundary probe: a body ending in CR ("\r") followed by render's "\n"
        // forms a Swift CRLF extended grapheme cluster, which breaks `hasSuffix("\n")` on line 62.
        let body = "line with trailing CR\r"
        let rendered = OwnedBlocks.render(id: "cr_1", body: body)
        let parsed = OwnedBlocks.body(id: "cr_1", in: rendered)
        XCTAssertEqual(
            parsed, body,
            "OwnedBlocks.parse must round-trip body ending with U+000D (CR); got \(String(describing: parsed).debugDescription)"
        )
    }

    func testOwnedBlocksUserTextByteInvariantAndModelRefinement() {
        let seed = FormalConfig.seed ^ 0x02
        var rng = SplitMix64(seed: seed)
        let cases = FormalConfig.cases

        for i in 0..<cases {
            let initialSliceCount = rng.nextInt(in: 1...4)
            var initialUserSlices: [String] = []
            var doc = ""
            var oracle: [String: String] = [:]
            let idPool = (0..<5).map { "b\($0)" }

            // Build randomized interleaved user slices and initial owned blocks.
            for s in 0..<initialSliceCount {
                let user = rng.randomSafeSlice(minLen: 0, maxLen: 5)
                initialUserSlices.append(user)
                doc += user
                if s < initialSliceCount - 1 && rng.nextBool(probabilityTrue: 0.6) {
                    let id = idPool[s]
                    let body = rng.randomBlockBody()
                    doc += OwnedBlocks.render(id: id, body: body)
                    oracle[id] = body
                }
            }

            let stepCount = rng.nextInt(in: 8...18)
            for step in 0..<stepCount {
                let id = rng.pick(idPool)
                let doUpsert = rng.nextBool(probabilityTrue: 0.65)
                if doUpsert {
                    let body = rng.randomBlockBody()
                    let existed = oracle[id] != nil
                    let userPiecesBefore = OwnedBlocksInvariant.userPieces(doc)

                    doc = OwnedBlocks.upsert(doc, id: id, body: body)
                    oracle[id] = body

                    // In-place replacement must preserve EVERY user slice byte-for-byte.
                    if existed {
                        XCTAssertEqual(
                            OwnedBlocksInvariant.userPieces(doc),
                            userPiecesBefore,
                            "\(FormalConfig.seedTag(seed, caseIndex: i)) step \(step): in-place upsert mutated user slices"
                        )
                    }
                } else {
                    doc = OwnedBlocks.remove(doc, id: id)
                    oracle.removeValue(forKey: id)
                }

                // Check UserTextByteInvariant after every operation.
                if let violation = OwnedBlocksInvariant.checkUserPreservation(initialUserSlices: initialUserSlices, document: doc) {
                    XCTFail("\(FormalConfig.seedTag(seed, caseIndex: i)) step \(step): \(violation)")
                    return
                }

                // Check refinement against reference model [id: body].
                let parsedOwned = OwnedBlocks.parse(doc).compactMap { piece -> (String, String)? in
                    guard let id = piece.id else { return nil }
                    return (id, piece.body)
                }
                let parsedMap = Dictionary(uniqueKeysWithValues: parsedOwned)
                XCTAssertEqual(
                    parsedOwned.count, parsedMap.count,
                    "\(FormalConfig.seedTag(seed, caseIndex: i)) step \(step): duplicate owned block ids"
                )
                XCTAssertEqual(
                    parsedMap, oracle,
                    "\(FormalConfig.seedTag(seed, caseIndex: i)) step \(step): parsed blocks diverged from oracle"
                )
            }
        }
    }

    func testOwnedBlocksUpsertIdempotence() {
        let seed = FormalConfig.seed ^ 0x03
        var rng = SplitMix64(seed: seed)
        let cases = FormalConfig.cases

        for i in 0..<cases {
            var doc = rng.nextBool(probabilityTrue: 0.15) ? "" : rng.randomSafeSlice(minLen: 0, maxLen: 8)
            if rng.nextBool(probabilityTrue: 0.5) {
                doc = OwnedBlocks.upsert(doc, id: "existing", body: rng.randomBlockBody())
            }
            let id = rng.nextBool(probabilityTrue: 0.5) ? "existing" : rng.randomBlockId()
            let body = rng.randomBlockBody()

            let once = OwnedBlocks.upsert(doc, id: id, body: body)
            let twice = OwnedBlocks.upsert(once, id: id, body: body)
            XCTAssertEqual(
                twice, once,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) upsert not idempotent for id=\(id)"
            )
        }
    }

    func testOwnedBlocksRepeatedUpsertRemoveDoesNotAccumulateBlankLines() {
        let seed = FormalConfig.seed ^ 0x04
        var rng = SplitMix64(seed: seed)
        let cases = min(FormalConfig.cases, 50)

        for i in 0..<cases {
            let initial = rng.nextBool(probabilityTrue: 0.2)
                ? "My reading notes\n"
                : rng.randomSafeSlice(minLen: 1, maxLen: 6) + "\n"
            var doc = initial
            let cycles = 10

            var lengths: [Int] = []
            for c in 0..<cycles {
                doc = OwnedBlocks.upsert(doc, id: "ephemeral", body: "note \(c)")
                doc = OwnedBlocks.remove(doc, id: "ephemeral")
                lengths.append(doc.utf8.count)
            }

            // A bounded separator cleanup must stabilize after at most 1 cycle (no unbounded blank-line growth).
            let trailingNewlines = doc.reversed().prefix(while: { $0 == "\n" }).count
            let initialTrailing = initial.reversed().prefix(while: { $0 == "\n" }).count
            if trailingNewlines > initialTrailing + 2 {
                XCTFail(
                    "\(FormalConfig.seedTag(seed, caseIndex: i)) repeated upsert/remove accumulated unbounded blank lines: initialTrailing=\(initialTrailing), after \(cycles) cycles trailingNewlines=\(trailingNewlines), lengths=\(lengths)"
                )
                return
            }
        }
    }

    // MARK: VaultSync.applyExternal Formal Properties

    func testVaultSyncUnchangedDiskIsExactNoOp() {
        let seed = FormalConfig.seed ^ 0x05
        var rng = SplitMix64(seed: seed)
        let cases = FormalConfig.cases

        for i in 0..<cases {
            var doc = rng.randomSafeSlice(minLen: 0, maxLen: 6)
            var pending: [String: String] = [:]
            var written: [String: String] = [:]
            let count = rng.nextInt(in: 0...4)
            for k in 0..<count {
                let id = "b\(k)"
                let w = rng.randomBlockBody()
                doc = OwnedBlocks.upsert(doc, id: id, body: w)
                written[id] = w
                pending[id] = rng.nextBool() ? w : rng.randomBlockBody()
            }
            let state = VaultSyncState(disk: doc, pending: pending, written: written)
            let result = VaultSync.applyExternal(state, disk: doc)
            XCTAssertEqual(result.state, state, "\(FormalConfig.seedTag(seed, caseIndex: i)) unchanged disk must be an exact no-op")
            XCTAssertTrue(result.conflicts.isEmpty, "\(FormalConfig.seedTag(seed, caseIndex: i)) unchanged disk must report zero conflicts")
            XCTAssertTrue(VaultSync.isOwnWrite(newDisk: doc, lastWritten: doc))
            XCTAssertFalse(VaultSync.isOwnWrite(newDisk: doc, lastWritten: nil))
            XCTAssertFalse(VaultSync.isOwnWrite(newDisk: doc + "x", lastWritten: doc))
        }
    }

    func testVaultSyncThreeWayMergeConflictAndNoSilentClobber() {
        let seed = FormalConfig.seed ^ 0x06
        var rng = SplitMix64(seed: seed)
        let cases = FormalConfig.cases

        for i in 0..<cases {
            // Build document with user text before, between, and after blocks.
            let blockCount = rng.nextInt(in: 1...5)
            let ids = (0..<blockCount).map { "blk_\($0)" }
            let userSlices = (0...blockCount).map { _ in
                let s = rng.randomSafeSlice(minLen: 1, maxLen: 4, allowNewlines: false)
                return s + "\n"
            }

            var written: [String: String] = [:]
            var pending: [String: String] = [:]
            var remoteBodies: [String: String] = [:]
            var expectedConflicts: [String] = []
            var expectedReaderOnly: [String: String] = [:]
            var expectedDiskOnly: [String: String] = [:]
            var expectedConvergent: [String: String] = [:]

            var oldDisk = userSlices[0]
            var newDisk = userSlices[0]
            // Ensure newDisk != oldDisk even if all blocks are reader-only by tagging user text on newDisk.
            let externalUserTag = " [ext-\(i)]"
            newDisk = userSlices[0] + externalUserTag + "\n"
            var expectedUserPieces = [userSlices[0] + externalUserTag + "\n"]

            for idx in 0..<blockCount {
                let id = ids[idx]
                let base = "base_\(idx)_\(rng.randomNonWhitespaceASCIIWord(length: 4))"
                written[id] = base
                oldDisk += OwnedBlocks.render(id: id, body: base) + userSlices[idx + 1]

                let scenario = rng.nextInt(in: 0...4)
                switch scenario {
                case 0:
                    // True 3-way conflict: pending != written && remote != written && remote != pending
                    let p = "reader_\(idx)_\(rng.randomNonWhitespaceASCIIWord(length: 5))\nline2_\(idx)"
                    let r = "obsidian_\(idx)_\(rng.randomNonWhitespaceASCIIWord(length: 5))\nobs2_\(idx)"
                    pending[id] = p
                    remoteBodies[id] = r
                    expectedConflicts.append(id)
                    newDisk += OwnedBlocks.render(id: id, body: r) + userSlices[idx + 1]
                case 1:
                    // Only Reader changed
                    let p = "readerOnly_\(idx)_\(rng.randomNonWhitespaceASCIIWord(length: 5))"
                    pending[id] = p
                    remoteBodies[id] = base
                    expectedReaderOnly[id] = p
                    newDisk += OwnedBlocks.render(id: id, body: base) + userSlices[idx + 1]
                case 2:
                    // Only disk changed
                    let r = "diskOnly_\(idx)_\(rng.randomNonWhitespaceASCIIWord(length: 5))"
                    pending[id] = base
                    remoteBodies[id] = r
                    expectedDiskOnly[id] = r
                    newDisk += OwnedBlocks.render(id: id, body: r) + userSlices[idx + 1]
                case 3:
                    // Convergent edit (both sides changed to identical body)
                    let both = "same_\(idx)_\(rng.randomNonWhitespaceASCIIWord(length: 5))"
                    pending[id] = both
                    remoteBodies[id] = both
                    expectedConvergent[id] = both
                    newDisk += OwnedBlocks.render(id: id, body: both) + userSlices[idx + 1]
                default:
                    // Neither changed
                    pending[id] = base
                    remoteBodies[id] = base
                    expectedDiskOnly[id] = base
                    newDisk += OwnedBlocks.render(id: id, body: base) + userSlices[idx + 1]
                }
                expectedUserPieces.append(userSlices[idx + 1])
            }

            let state = VaultSyncState(disk: oldDisk, pending: pending, written: written)
            let (next, conflicts) = VaultSync.applyExternal(state, disk: newDisk)

            // 1. Exact conflict set (sorted by id).
            XCTAssertEqual(
                conflicts, expectedConflicts.sorted(),
                "\(FormalConfig.seedTag(seed, caseIndex: i)) conflict set mismatch"
            )

            // 2. Every conflict keeps BOTH pending and remote bodies (zero silent clobber).
            for id in expectedConflicts {
                guard let mergedBody = OwnedBlocks.body(id: id, in: next.disk) else {
                    XCTFail("\(FormalConfig.seedTag(seed, caseIndex: i)) missing merged block \(id)")
                    return
                }
                let p = pending[id]!
                let r = remoteBodies[id]!
                XCTAssertTrue(
                    mergedBody.contains(p),
                    "\(FormalConfig.seedTag(seed, caseIndex: i)) conflict block \(id) dropped Reader pending body"
                )
                for remoteLine in r.split(separator: "\n", omittingEmptySubsequences: false) {
                    XCTAssertTrue(
                        mergedBody.contains(String(remoteLine)),
                        "\(FormalConfig.seedTag(seed, caseIndex: i)) conflict block \(id) dropped remote line \(remoteLine)"
                    )
                }
            }

            // 3. Reader-only changes win with zero conflicts.
            for (id, expectedBody) in expectedReaderOnly {
                XCTAssertEqual(
                    OwnedBlocks.body(id: id, in: next.disk), expectedBody,
                    "\(FormalConfig.seedTag(seed, caseIndex: i)) reader-only block \(id) did not win"
                )
            }

            // 4. Disk-only and convergent changes are preserved verbatim.
            for (id, expectedBody) in expectedDiskOnly {
                XCTAssertEqual(
                    OwnedBlocks.body(id: id, in: next.disk), expectedBody,
                    "\(FormalConfig.seedTag(seed, caseIndex: i)) disk-only block \(id) not preserved verbatim"
                )
            }
            for (id, expectedBody) in expectedConvergent {
                XCTAssertEqual(
                    OwnedBlocks.body(id: id, in: next.disk), expectedBody,
                    "\(FormalConfig.seedTag(seed, caseIndex: i)) convergent block \(id) not preserved"
                )
            }

            // 5. User text outside owned blocks is unchanged byte-for-byte.
            XCTAssertEqual(
                OwnedBlocksInvariant.userPieces(next.disk),
                expectedUserPieces,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) VaultSync.applyExternal mutated user text outside owned blocks"
            )
        }
    }

    // MARK: Updater & UpdateSwapScript Formal Properties

    func testUpdateEvaluatorRefinesOracleAndNeverDowngradesNonDev() throws {
        let seed = FormalConfig.seed ^ 0x07
        var rng = SplitMix64(seed: seed)
        let cases = FormalConfig.cases
        let artifactKey = "macos-app-arm64"

        for i in 0..<cases {
            let manifestBuild = rng.nextInt(in: 1...200)
            let currentBuild = rng.nextInt(in: 0...200)
            let manifestSHA = rng.randomHex(length: 40)
            let sameSHA = rng.nextBool(probabilityTrue: 0.35)
            let isDevCurrent = rng.nextBool(probabilityTrue: 0.3)
            let currentChannel = isDevCurrent ? rng.pick(["dev", "beta", ""]) : "main"
            let currentCommit = isDevCurrent
                ? rng.pick(["", "dev", rng.randomHex(length: 40)])
                : (sameSHA ? manifestSHA : rng.randomHex(length: 40))
            let allowDev = rng.nextBool()
            let artifactDigest = rng.randomHex(length: 64, allowUppercase: true)

            let manifest = UpdateManifest(
                schemaVersion: 1,
                channel: "main",
                version: "1.0-main.\(manifestBuild)+\(manifestSHA.prefix(7))",
                buildNumber: manifestBuild,
                commitSHA: manifestSHA,
                publishedAt: "2026-11-28T04:00:00Z",
                releaseURL: "https://github.com/ArturoKuang/reader/releases/tag/main-\(manifestBuild)",
                notes: "- test",
                artifacts: [
                    artifactKey: UpdateArtifact(
                        url: "\(UpdateEvaluator.defaultAllowedURLPrefix)main-\(manifestBuild)/Reader.zip",
                        sha256: artifactDigest,
                        size: UInt64(rng.nextInt(in: 1...100_000_000))
                    ),
                ]
            )
            let current = AppBuildInfo(
                version: "1.0",
                marketingVersion: "1.0",
                buildNumber: currentBuild,
                channel: currentChannel,
                commitSHA: currentCommit,
                builtAt: "2026-11-27T00:00:00Z"
            )

            let actual = try UpdateEvaluator.evaluate(
                manifest: manifest,
                current: current,
                artifactKey: artifactKey,
                allowDevUpgrade: allowDev
            )
            let oracle = UpdatePolicyOracle.evaluate(
                manifest: manifest,
                current: current,
                artifactKey: artifactKey,
                allowDevUpgrade: allowDev,
                allowedURLPrefix: UpdateEvaluator.defaultAllowedURLPrefix
            )

            switch oracle {
            case .success(let expected):
                XCTAssertEqual(
                    actual, expected,
                    "\(FormalConfig.seedTag(seed, caseIndex: i)) evaluator disagreed with oracle"
                )
            case .failure(let err):
                XCTFail("\(FormalConfig.seedTag(seed, caseIndex: i)) unexpected oracle failure \(err)")
            }

            // Explicit monotonicity / anti-downgrade safety invariant for non-dev builds.
            if !current.isDev && manifest.buildNumber < current.buildNumber {
                XCTAssertEqual(
                    actual, .upToDate,
                    "\(FormalConfig.seedTag(seed, caseIndex: i)) non-dev build downgraded from \(current.buildNumber) to \(manifest.buildNumber)"
                )
            }
            if case .available(let release) = actual {
                XCTAssertEqual(release.artifact.sha256, artifactDigest.lowercased())
            }
        }
    }

    func testUpdateEvaluatorRejectsInvalidManifestsWithExactPolicyErrors() {
        let seed = FormalConfig.seed ^ 0x08
        var rng = SplitMix64(seed: seed)
        let cases = FormalConfig.cases
        let artifactKey = "macos-app-arm64"
        let validURL = "\(UpdateEvaluator.defaultAllowedURLPrefix)main-100/Reader.zip"
        let validDigest = String(repeating: "a", count: 64)
        let current = AppBuildInfo(
            version: "1.0-main.50+1111111",
            marketingVersion: "1.0",
            buildNumber: 50,
            channel: "main",
            commitSHA: String(repeating: "1", count: 40),
            builtAt: "2026-11-27T00:00:00Z"
        )

        for i in 0..<cases {
            let faultKind = i % 9
            var manifest = UpdateManifest(
                schemaVersion: 1,
                channel: "main",
                version: "1.0-main.100+aaaaaaa",
                buildNumber: 100,
                commitSHA: rng.randomHex(length: 40),
                publishedAt: "2026-11-28T04:00:00Z",
                releaseURL: "https://github.com/ArturoKuang/reader/releases/tag/main-100",
                notes: "",
                artifacts: [artifactKey: UpdateArtifact(url: validURL, sha256: validDigest, size: 1024)]
            )

            switch faultKind {
            case 0:
                let badSchema = rng.pick([0, -1, 2, 3, 99])
                manifest.schemaVersion = badSchema
                assertPolicyError(manifest, current, artifactKey, tag: FormalConfig.seedTag(seed, caseIndex: i)) { error in
                    XCTAssertEqual(error, .unsupportedSchemaVersion(badSchema))
                }
            case 1:
                manifest.channel = rng.pick(["dev", "nightly", "Main", "", "beta"])
                assertPolicyError(manifest, current, artifactKey, tag: FormalConfig.seedTag(seed, caseIndex: i)) { error in
                    guard case .invalidManifest = error else {
                        return XCTFail("expected .invalidManifest for bad channel, got \(error)")
                    }
                }
            case 2:
                manifest.buildNumber = rng.pick([0, -1, -500])
                assertPolicyError(manifest, current, artifactKey, tag: FormalConfig.seedTag(seed, caseIndex: i)) { error in
                    guard case .invalidManifest = error else {
                        return XCTFail("expected .invalidManifest for non-positive build, got \(error)")
                    }
                }
            case 3:
                manifest.commitSHA = rng.pick(["", "   ", "\n\t"])
                assertPolicyError(manifest, current, artifactKey, tag: FormalConfig.seedTag(seed, caseIndex: i)) { error in
                    guard case .invalidManifest = error else {
                        return XCTFail("expected .invalidManifest for empty commitSHA, got \(error)")
                    }
                }
            case 4:
                manifest.artifacts = ["linux-x64": UpdateArtifact(url: validURL, sha256: validDigest, size: 1024)]
                assertPolicyError(manifest, current, artifactKey, tag: FormalConfig.seedTag(seed, caseIndex: i)) { error in
                    XCTAssertEqual(error, .missingArtifact(artifactKey))
                }
            case 5:
                let httpURL = "http://github.com/ArturoKuang/reader/releases/download/main-100/Reader.zip"
                manifest.artifacts[artifactKey] = UpdateArtifact(url: httpURL, sha256: validDigest, size: 1024)
                assertPolicyError(manifest, current, artifactKey, tag: FormalConfig.seedTag(seed, caseIndex: i)) { error in
                    XCTAssertEqual(error, .invalidArtifactURL(httpURL))
                }
            case 6:
                let untrustedURL = rng.pick([
                    "https://evil.example/reader/Reader.zip",
                    "https://github.com/OtherUser/reader/releases/download/main-100/Reader.zip",
                    "file:///tmp/Reader.zip",
                    "ftp://github.com/ArturoKuang/reader/releases/download/main-100/Reader.zip",
                    "not a url",
                ])
                manifest.artifacts[artifactKey] = UpdateArtifact(url: untrustedURL, sha256: validDigest, size: 1024)
                assertPolicyError(manifest, current, artifactKey, tag: FormalConfig.seedTag(seed, caseIndex: i)) { error in
                    XCTAssertEqual(error, .invalidArtifactURL(untrustedURL))
                }
            case 7:
                let badLenSHA = rng.randomHex(length: rng.pick([0, 32, 63, 65, 128]))
                manifest.artifacts[artifactKey] = UpdateArtifact(url: validURL, sha256: badLenSHA, size: 1024)
                assertPolicyError(manifest, current, artifactKey, tag: FormalConfig.seedTag(seed, caseIndex: i)) { error in
                    XCTAssertEqual(error, .invalidChecksumFormat(badLenSHA))
                }
            default:
                let nonHexSHA = String(repeating: "a", count: 63) + rng.pick(["g", "z", " ", "-", "!"])
                manifest.artifacts[artifactKey] = UpdateArtifact(url: validURL, sha256: nonHexSHA, size: 1024)
                assertPolicyError(manifest, current, artifactKey, tag: FormalConfig.seedTag(seed, caseIndex: i)) { error in
                    XCTAssertEqual(error, .invalidChecksumFormat(nonHexSHA))
                }
            }
        }
    }

    private func assertPolicyError(
        _ manifest: UpdateManifest,
        _ current: AppBuildInfo,
        _ artifactKey: String,
        tag: String,
        verify: (UpdatePolicyError) -> Void
    ) {
        do {
            let decision = try UpdateEvaluator.evaluate(
                manifest: manifest,
                current: current,
                artifactKey: artifactKey,
                allowDevUpgrade: true
            )
            XCTFail("\(tag) expected UpdatePolicyError, got \(decision)")
        } catch let error as UpdatePolicyError {
            verify(error)
        } catch {
            XCTFail("\(tag) expected UpdatePolicyError, got \(error)")
        }
    }

    func testUpdateSwapScriptShellQuoteRoundTripsThroughPosixSh() throws {
        let seed = FormalConfig.seed ^ 0x09
        var rng = SplitMix64(seed: seed)
        let canaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-shellquote-canary-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: canaryFile) }

        var inputs: [String] = [
            "",
            "/Applications/Reader.app",
            "/Users/O'Brien/My Applications/Reader's.app",
            "'",
            "'''",
            "\"double quotes\"",
            "/tmp/$(touch \(canaryFile))/Reader.app",
            "/tmp/`touch \(canaryFile)`/Reader.app",
            "/tmp/$HOME/${USER}/$((1+1))/Reader.app",
            "/tmp/a;touch \(canaryFile);b|c&d>e<f/Reader.app",
            "/tmp/glob*?[a-z]\\escape/Reader.app",
            "/tmp/line1\nline2\tline3/Reader.app",
            "-rf /",
            "/Users/café/日本語/Reader.app",
        ]

        let hostileAlphabet = Array("abc123 /._-'\"$`\\;|&><*?[](){}\n\t!~#=")
        let extraCount = min(max(FormalConfig.cases / 10, 12), 25)
        for _ in 0..<extraCount {
            let len = rng.nextInt(in: 1...35)
            inputs.append(String((0..<len).map { _ in rng.pick(hostileAlphabet) }))
        }

        for (idx, value) in inputs.enumerated() {
            let quoted = UpdateSwapScript.shellQuote(value)
            XCTAssertTrue(quoted.hasPrefix("'") && quoted.hasSuffix("'"), "\(FormalConfig.seedTag(seed, caseIndex: idx)) shellQuote not wrapped in single quotes")

            // Execute /bin/sh -c "printf -- '%s' <quoted>" and check byte-exact round-trip.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf -- '%s' \(quoted)"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            try process.run()
            process.waitUntilExit()

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let outString = String(data: outData, encoding: .utf8)
            let errString = String(data: errData, encoding: .utf8) ?? ""

            XCTAssertEqual(
                process.terminationStatus, 0,
                "\(FormalConfig.seedTag(seed, caseIndex: idx)) /bin/sh failed (stderr=\(errString)) for value=\(value.debugDescription)"
            )
            XCTAssertEqual(
                outString, value,
                "\(FormalConfig.seedTag(seed, caseIndex: idx)) shellQuote round-trip mismatch for value=\(value.debugDescription)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: canaryFile),
                "\(FormalConfig.seedTag(seed, caseIndex: idx)) shell injection executed canary command for value=\(value.debugDescription)"
            )
        }

        // Verify UpdateSwapScript.build embeds properly quoted target/staged/backup paths.
        let hostileTarget = "/Users/O'Brien/$(id)/Reader.app"
        let script = UpdateSwapScript.build(
            parentPid: 1234,
            targetAppPath: hostileTarget,
            stagedAppPath: "/tmp/stage `uname`/Reader.app",
            backupAppPath: "/tmp/back;rm/Reader.app",
            launchUpdated: false
        )
        XCTAssertTrue(script.contains("TARGET=\(UpdateSwapScript.shellQuote(hostileTarget))"))
        XCTAssertTrue(script.contains("LAUNCH=0"))
    }

    // MARK: EPUBCFI, Reanchorer, & WordStore.normalize Formal Properties

    func testEPUBCFIMakeParseRoundTrip() {
        let seed = FormalConfig.seed ^ 0x0A
        var rng = SplitMix64(seed: seed)
        let cases = FormalConfig.cases

        for i in 0..<cases {
            let spine = rng.nextInt(in: 0...500)
            let start = rng.nextInt(in: 0...50_000)
            let end = start + rng.nextInt(in: 0...5_000)
            let intra = rng.pick(["/4", "4", "/4/2/10", "/2/8"])

            let made = EPUBCFI.make(spineIndex: spine, start: start, end: end, intraPath: intra)
            let parsed = EPUBCFI(value: made.value)

            XCTAssertNotNil(parsed, "\(FormalConfig.seedTag(seed, caseIndex: i)) failed to parse \(made.value)")
            XCTAssertEqual(parsed, made, "\(FormalConfig.seedTag(seed, caseIndex: i)) EPUBCFI struct round-trip mismatch")
            XCTAssertEqual(parsed?.spineIndex, spine, "\(FormalConfig.seedTag(seed, caseIndex: i)) spineIndex mismatch")
            XCTAssertEqual(parsed?.startOffset, start, "\(FormalConfig.seedTag(seed, caseIndex: i)) startOffset mismatch")
            XCTAssertEqual(parsed?.endOffset, end, "\(FormalConfig.seedTag(seed, caseIndex: i)) endOffset mismatch")
            XCTAssertEqual(parsed?.value, made.value)
        }

        // Reject malformed inputs & odd spine steps.
        XCTAssertNil(EPUBCFI(value: ""))
        XCTAssertNil(EPUBCFI(value: "not-a-cfi"))
        XCTAssertNil(EPUBCFI(value: "epubcfi(/6/4!"))
        XCTAssertNil(EPUBCFI(value: "epubcfi(/6/3!/4,/1:0,/1:5)")?.spineIndex)
        XCTAssertNil(EPUBCFI(value: "epubcfi(/6/0!/4,/1:0,/1:5)")?.spineIndex)
    }

    func testReanchorerPrefersExactContextAndBoundsReturnedContext() {
        let seed = FormalConfig.seed ^ 0x0B
        var rng = SplitMix64(seed: seed)
        let cases = FormalConfig.cases

        for i in 0..<cases {
            let quote = "TARGET_\(rng.randomNonWhitespaceASCIIWord(length: 8))"
            let longBefore = String(repeating: "L", count: rng.nextInt(in: 85...150)) + " PRE_\(i) "
            let longAfter = " SUF_\(i) " + String(repeating: "R", count: rng.nextInt(in: 85...150))
            let wantedPrefix = String(longBefore.suffix(rng.nextInt(in: 8...30)))
            let wantedSuffix = String(longAfter.prefix(rng.nextInt(in: 8...30)))

            let sliceCount = rng.nextInt(in: 2...5)
            let targetSliceIdx = rng.nextInt(in: 1...(sliceCount - 1))
            var slices: [TextSlice] = []

            for s in 0..<sliceCount {
                let decoyCount = rng.nextInt(in: 1...3)
                var parts: [String] = []
                for d in 0..<decoyCount {
                    parts.append("decoy_before_\(s)_\(d) \(quote) decoy_after_\(s)_\(d)")
                }
                if s == targetSliceIdx {
                    parts.append(longBefore + quote + longAfter)
                    parts.append("trailing_decoy_\(s) \(quote) trailing_after_\(s)")
                }
                slices.append(TextSlice(
                    page: s + 1,
                    spineIndex: s,
                    section: "Chapter \(s + 1)",
                    text: parts.joined(separator: " | ")
                ))
            }

            let corpus = TextCorpus(slices: slices)
            let hit = Reanchorer.locate(quote: "  \(quote)\n", prefix: wantedPrefix, suffix: wantedSuffix, in: corpus)

            XCTAssertNotNil(hit, "\(FormalConfig.seedTag(seed, caseIndex: i)) failed to locate exact-context quote")
            XCTAssertEqual(
                hit?.confidence, .exactContext,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) must prefer .exactContext over earlier duplicate quote"
            )
            XCTAssertEqual(
                hit?.page, targetSliceIdx + 1,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) matched wrong slice page"
            )
            XCTAssertEqual(hit?.spineIndex, targetSliceIdx)
            XCTAssertEqual(hit?.section, "Chapter \(targetSliceIdx + 1)")
            XCTAssertLessThanOrEqual(
                hit?.prefix.count ?? Int.max, 80,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) returned prefix exceeded 80 chars"
            )
            XCTAssertLessThanOrEqual(
                hit?.suffix.count ?? Int.max, 80,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) returned suffix exceeded 80 chars"
            )
            XCTAssertTrue(
                hit?.prefix.hasSuffix(wantedPrefix) == true,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) returned prefix does not end with matched context"
            )
            XCTAssertTrue(
                hit?.suffix.hasPrefix(wantedSuffix) == true,
                "\(FormalConfig.seedTag(seed, caseIndex: i)) returned suffix does not start with matched context"
            )

            // Verify generated CFI parses back cleanly.
            if let cfiStr = hit?.cfi, let cfi = EPUBCFI(value: cfiStr) {
                XCTAssertEqual(cfi.spineIndex, targetSliceIdx)
                XCTAssertEqual((cfi.endOffset ?? 0) - (cfi.startOffset ?? 0), quote.count)
            } else {
                XCTFail("\(FormalConfig.seedTag(seed, caseIndex: i)) missing/invalid CFI on spine slice")
            }

            // When context matches NO occurrence, locate must fall back to .quoteOnly at slice 0.
            let fallback = Reanchorer.locate(quote: quote, prefix: "NONEXISTENT_PREFIX", suffix: "NONEXISTENT_SUFFIX", in: corpus)
            XCTAssertEqual(fallback?.confidence, .quoteOnly)
            XCTAssertEqual(fallback?.page, 1)
            XCTAssertLessThanOrEqual(fallback?.prefix.count ?? Int.max, 80)
            XCTAssertLessThanOrEqual(fallback?.suffix.count ?? Int.max, 80)

            // Absent or whitespace-only quotes must return nil.
            XCTAssertNil(Reanchorer.locate(quote: "   \n\t ", prefix: "", suffix: "", in: corpus))
            XCTAssertNil(Reanchorer.locate(quote: "ABSENT_\(i)", prefix: "", suffix: "", in: corpus))
        }
    }

    func testWordStoreNormalizeIdempotenceAndUnicodeContract() {
        let seed = FormalConfig.seed ^ 0x0C
        var rng = SplitMix64(seed: seed)
        let cases = FormalConfig.cases

        let unicodePieces = [
            "Hello", "PROGENY", "ΟΔΟΣ", "λόγος", "ΛΌΓΟς", "ς", "Σ", "σ",
            "İSTANBUL", "Straße", "STRAẞE", "caf\u{00E9}", "cafe\u{0301}",
            "漢字", "読書", "Don't", "Don\u{2019}t", "well-known", "😀",
            "Family\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
            " ", "\t", "\n", "\r\n", "\u{0085}", "\u{00A0}", "\u{2028}", "\u{2029}", "\u{3000}", "\u{FEFF}", "\u{200B}",
        ]

        for i in 0..<cases {
            let count = rng.nextInt(in: 0...6)
            let word = (0..<count).map { _ in rng.pick(unicodePieces) }.joined()
            let once = WordStore.normalize(word)
            let twice = WordStore.normalize(once)
            XCTAssertEqual(
                Array(twice.unicodeScalars),
                Array(once.unicodeScalars),
                "\(FormalConfig.seedTag(seed, caseIndex: i)) WordStore.normalize not idempotent for \(word.debugDescription)"
            )
        }

        // Specific cross-platform Unicode invariants.
        XCTAssertEqual(
            Array(WordStore.normalize("ΟΔΟΣ").unicodeScalars.map(\.value)),
            [0x03BF, 0x03B4, 0x03BF, 0x03C3],
            "Word-final Greek Σ must normalize to σ (U+03C3), not ς"
        )
        XCTAssertEqual(
            Array(WordStore.normalize("λόγος").unicodeScalars.map(\.value)),
            [0x03BB, 0x03CC, 0x03B3, 0x03BF, 0x03C2],
            "Lowercase Greek final sigma ς (U+03C2) must be preserved"
        )
        XCTAssertEqual(
            Array(WordStore.normalize("\u{039B}\u{038C}\u{0393}\u{039F}\u{03C2}").unicodeScalars.map(\.value)),
            [0x03BB, 0x03CC, 0x03B3, 0x03BF, 0x03C2]
        )
        XCTAssertEqual(
            Array(WordStore.normalize("\u{FEFF}word").unicodeScalars.map(\.value)),
            [0xFEFF, 0x0077, 0x006F, 0x0072, 0x0064],
            "Leading U+FEFF must NOT be trimmed"
        )
        XCTAssertEqual(
            Array(WordStore.normalize("\u{0085}word\u{0085}").unicodeScalars.map(\.value)),
            [0x0077, 0x006F, 0x0072, 0x0064],
            "U+0085 (NEL) must be trimmed"
        )
        XCTAssertEqual(
            Array(WordStore.normalize("İSTANBUL").unicodeScalars.map(\.value)),
            [0x0069, 0x0307, 0x0073, 0x0074, 0x0061, 0x006E, 0x0062, 0x0075, 0x006C]
        )
        XCTAssertEqual(
            Array(WordStore.normalize("STRAẞE").unicodeScalars.map(\.value)),
            [0x0073, 0x0074, 0x0072, 0x0061, 0x00DF, 0x0065]
        )
        XCTAssertNotEqual(
            Array(WordStore.normalize("caf\u{00E9}").unicodeScalars.map(\.value)),
            Array(WordStore.normalize("cafe\u{0301}").unicodeScalars.map(\.value)),
            "NFC and NFD spellings must remain distinct (no Unicode normalization)"
        )
        XCTAssertEqual(WordStore.normalize("\u{2028}word\u{3000}"), "word")
        XCTAssertEqual(WordStore.normalize("\u{00A0}word\u{00A0}"), "word")
        XCTAssertEqual(WordStore.normalize("ice\u{00A0}cream"), "ice\u{00A0}cream")
        XCTAssertEqual(WordStore.normalize("ice\tcream"), "ice\tcream")
        XCTAssertEqual(WordStore.normalize(" \t\n\u{00A0}\u{3000}\u{0085}"), "")
    }

    func testWordStoreNormalizeCrossPlatformTrimSetMatchesMobileContract() {
        // apps/mobile/src/contract/wordId.ts:7-9 & wordId.test.ts:37 assume
        // Swift's CharacterSet.whitespacesAndNewlines == (Zs | Zl | Zp | U+0009..U+000D | U+0085),
        // which excludes U+200B (Cf). However, Apple's Foundation CharacterSet.whitespacesAndNewlines
        // still includes U+200B (legacy Unicode 3.2 Zs), causing Mac and Mobile to compute different wordIds.
        let actual = WordStore.normalize("\u{200B}word")
        XCTAssertEqual(
            Array(actual.unicodeScalars.map(\.value)),
            [0x200B, 0x0077, 0x006F, 0x0072, 0x0064],
            "Cross-platform wordId divergence: Swift WordStore.normalize trimmed U+200B (ZERO WIDTH SPACE) -> \(actual.debugDescription), whereas apps/mobile/src/contract/wordId.ts preserves U+200B"
        )
    }
}
