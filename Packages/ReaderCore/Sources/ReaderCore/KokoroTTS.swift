import Foundation

/// A curated Kokoro-82M English voice pack supported by the on-device Core ML runtime.
public struct KokoroVoice: Equatable, Hashable, Sendable, Identifiable {
    public enum Accent: String, Equatable, Hashable, Sendable, CaseIterable {
        case americanFemale = "American Female"
        case americanMale = "American Male"
        case britishFemale = "British Female"
        case britishMale = "British Male"
    }

    public let id: String
    public let name: String
    public let style: String
    public let accent: Accent

    public var label: String {
        "\(name) — \(style)"
    }

    public var shortAccent: String {
        switch accent {
        case .americanFemale: return "US Female"
        case .americanMale: return "US Male"
        case .britishFemale: return "UK Female"
        case .britishMale: return "UK Male"
        }
    }

    public init(id: String, name: String, style: String, accent: Accent) {
        self.id = id
        self.name = name
        self.style = style
        self.accent = accent
    }
}

/// Curated Kokoro-82M voice catalog shared by the player menu, Settings, and TTSEngine.
public enum KokoroVoiceCatalog {
    public struct Group: Equatable, Sendable {
        public let title: String
        public let voices: [KokoroVoice]

        public init(title: String, voices: [KokoroVoice]) {
            self.title = title
            self.voices = voices
        }
    }

    public static let defaultVoiceID = "af_heart"

    public static let allVoices: [KokoroVoice] = [
        // American Female
        KokoroVoice(id: "af_heart", name: "Heart", style: "Warm & Natural", accent: .americanFemale),
        KokoroVoice(id: "af_bella", name: "Bella", style: "Expressive", accent: .americanFemale),
        KokoroVoice(id: "af_nicole", name: "Nicole", style: "Soft & Gentle", accent: .americanFemale),
        KokoroVoice(id: "af_aoede", name: "Aoede", style: "Clear", accent: .americanFemale),
        KokoroVoice(id: "af_kore", name: "Kore", style: "Crisp", accent: .americanFemale),
        KokoroVoice(id: "af_sarah", name: "Sarah", style: "Calm", accent: .americanFemale),
        KokoroVoice(id: "af_nova", name: "Nova", style: "Bright", accent: .americanFemale),
        KokoroVoice(id: "af_sky", name: "Sky", style: "Light", accent: .americanFemale),
        KokoroVoice(id: "af_alloy", name: "Alloy", style: "Balanced", accent: .americanFemale),
        KokoroVoice(id: "af_jessica", name: "Jessica", style: "Conversational", accent: .americanFemale),
        KokoroVoice(id: "af_river", name: "River", style: "Neutral", accent: .americanFemale),

        // American Male
        KokoroVoice(id: "am_michael", name: "Michael", style: "Warm & Deep", accent: .americanMale),
        KokoroVoice(id: "am_fenrir", name: "Fenrir", style: "Rich Baritone", accent: .americanMale),
        KokoroVoice(id: "am_puck", name: "Puck", style: "Energetic", accent: .americanMale),
        KokoroVoice(id: "am_adam", name: "Adam", style: "Narrator", accent: .americanMale),
        KokoroVoice(id: "am_echo", name: "Echo", style: "Smooth", accent: .americanMale),
        KokoroVoice(id: "am_eric", name: "Eric", style: "Steady", accent: .americanMale),
        KokoroVoice(id: "am_liam", name: "Liam", style: "Natural", accent: .americanMale),
        KokoroVoice(id: "am_onyx", name: "Onyx", style: "Deep", accent: .americanMale),

        // British Female
        KokoroVoice(id: "bf_emma", name: "Emma", style: "Warm British", accent: .britishFemale),
        KokoroVoice(id: "bf_isabella", name: "Isabella", style: "Refined", accent: .britishFemale),
        KokoroVoice(id: "bf_alice", name: "Alice", style: "Crisp", accent: .britishFemale),
        KokoroVoice(id: "bf_lily", name: "Lily", style: "Gentle", accent: .britishFemale),

        // British Male
        KokoroVoice(id: "bm_george", name: "George", style: "Classic Narrator", accent: .britishMale),
        KokoroVoice(id: "bm_fable", name: "Fable", style: "Storyteller", accent: .britishMale),
        KokoroVoice(id: "bm_daniel", name: "Daniel", style: "Clear", accent: .britishMale),
        KokoroVoice(id: "bm_lewis", name: "Lewis", style: "Calm", accent: .britishMale),
    ]

    private static let byID: [String: KokoroVoice] = Dictionary(
        uniqueKeysWithValues: allVoices.map { ($0.id, $0) }
    )

    public static var defaultVoice: KokoroVoice {
        byID[defaultVoiceID] ?? allVoices[0]
    }

    public static func voice(for identifier: String?) -> KokoroVoice? {
        guard let identifier else { return nil }
        return byID[identifier]
    }

    /// Resolves a saved voice identifier into a Kokoro voice, smoothly migrating `nil`
    /// or legacy Apple `com.apple.voice.*` identifiers to the default Kokoro voice.
    public static func resolve(_ identifier: String?) -> KokoroVoice {
        voice(for: identifier) ?? defaultVoice
    }

    public static func groups() -> [Group] {
        KokoroVoice.Accent.allCases.compactMap { accent in
            let members = allVoices.filter { $0.accent == accent }
            return members.isEmpty ? nil : Group(title: accent.rawValue, voices: members)
        }
    }
}

/// Splits a user playback speed multiplier (0.5x...3.0x) into Kokoro's native
/// duration-predictor speed (up to 2.0x) and optional pitch-preserving time stretch
/// above 2.0x so speeds like 2.5x and 3.0x stay crisp without hitting minimum-frame ceilings.
public struct KokoroSpeedPlan: Equatable, Sendable {
    public static let maxNativeKokoroSpeed: Double = 2.0

    public let userRate: Double
    public let kokoroSpeed: Float
    public let timePitchRate: Float

    public var needsTimePitch: Bool {
        abs(timePitchRate - 1.0) > 0.001
    }

    public init(rate: Double) {
        let clamped = TTSRateMapper.clampedMultiplier(rate)
        userRate = clamped
        let native = min(clamped, Self.maxNativeKokoroSpeed)
        kokoroSpeed = Float(native)
        timePitchRate = clamped > Self.maxNativeKokoroSpeed ? Float(clamped / native) : 1.0
    }
}

/// Time interval of a single display word in a synthesized Kokoro audio buffer.
///
/// Times are expressed in **raw buffer seconds** (`0...rawAudioDuration`), matching
/// `AVAudioPlayerNode.playerTime(forNodeTime:)` directly regardless of any downstream
/// `AVAudioUnitTimePitch` rate.
public struct KokoroWordTiming: Equatable, Sendable {
    /// Word range relative to the full `TTSDocumentSegment.text`.
    public let utf16Range: TTSUTF16Range
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(utf16Range: TTSUTF16Range, startTime: TimeInterval, endTime: TimeInterval) {
        self.utf16Range = utf16Range
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Maps Kokoro's token-level `inputIds` and `predictedDurations` back onto the
/// original document segment's UTF-16 word ranges for karaoke-style active-word highlighting.
public enum KokoroWordAligner {
    public static let defaultSpaceTokenID: Int32 = 16
    public static let defaultBosEosTokenID: Int32 = 0
    /// Punctuation token IDs from Kokoro v1.0 `vocab.json` (`; : , . ! ? — … " ( ) “ ”`).
    /// FluidAudio emits leading punctuation (like `“` or `(`) as standalone space-separated
    /// tokens, so spans containing only punctuation IDs must be ignored during word alignment.
    public static let defaultPunctuationTokenIDs: Set<Int32> = [
        1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14, 15,
    ]

    public struct Span: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval

        public init(start: TimeInterval, end: TimeInterval) {
            self.start = start
            self.end = end
        }
    }

    /// Extracts spoken word spans (in raw audio seconds) from Kokoro's token IDs and
    /// acoustic-frame durations. Handles multi-chunk outputs with multiple BOS/EOS pairs
    /// and skips standalone punctuation spans such as opening quotes or brackets.
    public static func spokenWordSpans(
        inputIds: [Int32],
        predictedDurations: [Int32],
        rawAudioDuration: TimeInterval,
        spaceTokenID: Int32 = defaultSpaceTokenID,
        bosEosTokenID: Int32 = defaultBosEosTokenID,
        punctuationTokenIDs: Set<Int32> = defaultPunctuationTokenIDs
    ) -> [Span] {
        guard rawAudioDuration > 0,
              !inputIds.isEmpty,
              inputIds.count == predictedDurations.count else { return [] }

        let totalFrames = predictedDurations.reduce(0) { $0 + max(Int($1), 0) }
        guard totalFrames > 0 else { return [] }

        var frameSpans: [(start: Int, end: Int)] = []
        var cursor = 0
        var openStart: Int?
        var openEnd: Int?

        for idx in inputIds.indices {
            let id = inputIds[idx]
            let frames = max(Int(predictedDurations[idx]), 0)
            if id == bosEosTokenID || id == spaceTokenID {
                if let start = openStart, let end = openEnd {
                    frameSpans.append((start, end))
                }
                openStart = nil
                openEnd = nil
            } else if !punctuationTokenIDs.contains(id) {
                if openStart == nil {
                    openStart = cursor
                }
                openEnd = cursor + frames
            }
            cursor += frames
        }
        if let start = openStart, let end = openEnd {
            frameSpans.append((start, end))
        }

        let secondsPerFrame = rawAudioDuration / Double(totalFrames)
        return frameSpans.map { span in
            let s = min(max(Double(span.start) * secondsPerFrame, 0), rawAudioDuration)
            let e = min(max(Double(span.end) * secondsPerFrame, s), rawAudioDuration)
            return Span(start: s, end: e)
        }
    }

    /// Produces ordered, monotonic word timings for `sliceText` (offset by `sliceUTF16Offset`
    /// within the owning segment).
    public static func align(
        sliceText: String,
        sliceUTF16Offset: Int,
        rawAudioDuration: TimeInterval,
        inputIds: [Int32],
        predictedDurations: [Int32],
        normalizedText: String? = nil,
        spaceTokenID: Int32 = defaultSpaceTokenID,
        bosEosTokenID: Int32 = defaultBosEosTokenID,
        punctuationTokenIDs: Set<Int32> = defaultPunctuationTokenIDs
    ) -> [KokoroWordTiming] {
        let localRanges = TTSTextPlanner.wordRanges(in: sliceText)
        guard !localRanges.isEmpty else { return [] }
        let duration = max(rawAudioDuration, 0)
        guard duration > 0 else {
            return localRanges.map { range in
                KokoroWordTiming(
                    utf16Range: TTSUTF16Range(location: sliceUTF16Offset + range.location, length: range.length),
                    startTime: 0,
                    endTime: 0
                )
            }
        }

        let spoken = spokenWordSpans(
            inputIds: inputIds,
            predictedDurations: predictedDurations,
            rawAudioDuration: duration,
            spaceTokenID: spaceTokenID,
            bosEosTokenID: bosEosTokenID,
            punctuationTokenIDs: punctuationTokenIDs
        )

        let rawSpans: [Span]
        if spoken.isEmpty {
            rawSpans = proportionalSpans(for: localRanges, in: 0...duration)
        } else if spoken.count == localRanges.count {
            rawSpans = spoken
        } else {
            let displayTokens = localRanges.map { normalizeWord(slice(sliceText, range: $0)) }
            let spokenTokens = normalizedText.map(tokenizeSpokenWords) ?? []
            if spokenTokens.count == spoken.count, !spokenTokens.isEmpty {
                rawSpans = alignUsingAnchors(
                    displayRanges: localRanges,
                    displayTokens: displayTokens,
                    spokenTokens: spokenTokens,
                    spokenSpans: spoken,
                    totalDuration: duration
                )
            } else {
                rawSpans = proportionalToSpokenSpans(
                    displayRanges: localRanges,
                    spokenSpans: spoken,
                    totalDuration: duration
                )
            }
        }

        var result: [KokoroWordTiming] = []
        result.reserveCapacity(localRanges.count)
        var floorTime: TimeInterval = 0
        for (range, span) in zip(localRanges, rawSpans) {
            let start = min(max(span.start, floorTime), duration)
            let end = min(max(span.end, start), duration)
            floorTime = start
            result.append(KokoroWordTiming(
                utf16Range: TTSUTF16Range(location: sliceUTF16Offset + range.location, length: range.length),
                startTime: start,
                endTime: end
            ))
        }
        return result
    }

    /// Binary search for the active word at `playbackTime` (raw buffer seconds).
    /// Applies a slight lookahead tolerance so visual highlights feel crisp with audio output latency.
    public static func activeWordIndex(
        at playbackTime: TimeInterval,
        in timings: [KokoroWordTiming],
        leadSeconds: TimeInterval = 0.015
    ) -> Int? {
        guard !timings.isEmpty else { return nil }
        let target = max(playbackTime, 0) + max(leadSeconds, 0)
        if target < timings[0].startTime { return 0 }
        var low = 0
        var high = timings.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if timings[mid].startTime <= target {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    // MARK: - Helpers

    private static func slice(_ text: String, range: TTSUTF16Range) -> String {
        let ns = text as NSString
        guard range.location >= 0, range.end <= ns.length else { return "" }
        return ns.substring(with: range.nsRange)
    }

    private static func normalizeWord(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Mirrors Kokoro's English phonemizer word splitting (alphanumeric runs + internal apostrophes/hyphens).
    private static func tokenizeSpokenWords(_ text: String) -> [String] {
        let prepared = text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        var words: [String] = []
        var current = ""
        let chars = Array(prepared)
        for i in chars.indices {
            let ch = chars[i]
            let isJoiner = (ch == "'" || ch == "-")
                && !current.isEmpty
                && i + 1 < chars.count
                && (chars[i + 1].isLetter || chars[i + 1].isNumber)
            if ch.isLetter || ch.isNumber || isJoiner {
                current.append(ch)
            } else if !current.isEmpty {
                words.append(normalizeWord(current))
                current = ""
            }
        }
        if !current.isEmpty {
            words.append(normalizeWord(current))
        }
        return words
    }

    private static func alignUsingAnchors(
        displayRanges: [TTSUTF16Range],
        displayTokens: [String],
        spokenTokens: [String],
        spokenSpans: [Span],
        totalDuration: TimeInterval
    ) -> [Span] {
        let n = displayTokens.count
        let m = spokenTokens.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if !displayTokens[i].isEmpty && displayTokens[i] == spokenTokens[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var anchors: [(d: Int, s: Int)] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if !displayTokens[i].isEmpty && displayTokens[i] == spokenTokens[j] {
                anchors.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        if anchors.isEmpty {
            return proportionalToSpokenSpans(
                displayRanges: displayRanges,
                spokenSpans: spokenSpans,
                totalDuration: totalDuration
            )
        }

        var result = Array(repeating: Span(start: 0, end: 0), count: n)
        for (d, s) in anchors {
            result[d] = spokenSpans[s]
        }

        let sentinelPairs: [(dStart: Int, dEnd: Int, sStart: Int, sEnd: Int)] = {
            var gaps: [(Int, Int, Int, Int)] = []
            var prevD = -1
            var prevS = -1
            for anchor in anchors {
                if anchor.d > prevD + 1 {
                    gaps.append((prevD + 1, anchor.d, prevS + 1, anchor.s))
                }
                prevD = anchor.d
                prevS = anchor.s
            }
            if prevD + 1 < n {
                gaps.append((prevD + 1, n, prevS + 1, m))
            }
            return gaps
        }()

        for gap in sentinelPairs {
            let startBound: TimeInterval
            let endBound: TimeInterval
            if gap.sStart < gap.sEnd {
                startBound = spokenSpans[gap.sStart].start
                endBound = spokenSpans[gap.sEnd - 1].end
            } else {
                let left = gap.sStart > 0 ? spokenSpans[gap.sStart - 1].end : 0
                let right = gap.sStart < m ? spokenSpans[gap.sStart].start : totalDuration
                startBound = min(left, right)
                endBound = max(left, right)
            }
            let gapRanges = Array(displayRanges[gap.dStart..<gap.dEnd])
            let filled = proportionalSpans(for: gapRanges, in: startBound...endBound)
            for (offset, span) in filled.enumerated() {
                result[gap.dStart + offset] = span
            }
        }

        return result
    }

    private static func proportionalToSpokenSpans(
        displayRanges: [TTSUTF16Range],
        spokenSpans: [Span],
        totalDuration: TimeInterval
    ) -> [Span] {
        guard let first = spokenSpans.first, let last = spokenSpans.last else {
            return proportionalSpans(for: displayRanges, in: 0...totalDuration)
        }
        return proportionalSpans(for: displayRanges, in: first.start...max(last.end, first.start))
    }

    private static func proportionalSpans(
        for ranges: [TTSUTF16Range],
        in interval: ClosedRange<TimeInterval>
    ) -> [Span] {
        let count = ranges.count
        guard count > 0 else { return [] }
        let spanDuration = max(interval.upperBound - interval.lowerBound, 0)
        let weights = ranges.map { max(Double($0.length), 1.0) }
        let totalWeight = weights.reduce(0, +)
        var cursor = interval.lowerBound
        return weights.map { weight in
            let piece = totalWeight > 0 ? spanDuration * (weight / totalWeight) : 0
            let start = cursor
            let end = min(start + piece, interval.upperBound)
            cursor = end
            return Span(start: start, end: end)
        }
    }
}
