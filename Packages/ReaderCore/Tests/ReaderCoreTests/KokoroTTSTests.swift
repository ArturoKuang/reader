import XCTest
@testable import ReaderCore

final class KokoroTTSTests: XCTestCase {
    func testVoiceCatalogGroupsAndLegacyAppleVoiceMigration() {
        let groups = KokoroVoiceCatalog.groups()
        XCTAssertEqual(groups.map(\.title), ["American Female", "American Male", "British Female", "British Male"])
        XCTAssertEqual(KokoroVoiceCatalog.allVoices.count, 27)
        XCTAssertEqual(KokoroVoiceCatalog.resolve(nil).id, "af_heart")
        XCTAssertEqual(KokoroVoiceCatalog.resolve("com.apple.voice.enhanced.en-US.Samantha").id, "af_heart")
        XCTAssertEqual(KokoroVoiceCatalog.resolve("bf_emma").id, "bf_emma")
        XCTAssertEqual(KokoroVoiceCatalog.resolve("am_michael").shortAccent, "US Male")
        XCTAssertNil(KokoroVoiceCatalog.voice(for: "com.apple.speech.synthesis.voice.Alex"))
    }

    func testSpeedPlanSplitsNativeKokoroAndHighSpeedTimePitch() {
        let slow = KokoroSpeedPlan(rate: 0.75)
        XCTAssertEqual(slow.kokoroSpeed, 0.75, accuracy: 0.0001)
        XCTAssertEqual(slow.timePitchRate, 1.0, accuracy: 0.0001)
        XCTAssertFalse(slow.needsTimePitch)

        let double = KokoroSpeedPlan(rate: 2.0)
        XCTAssertEqual(double.kokoroSpeed, 2.0, accuracy: 0.0001)
        XCTAssertEqual(double.timePitchRate, 1.0, accuracy: 0.0001)
        XCTAssertFalse(double.needsTimePitch)

        let fast = KokoroSpeedPlan(rate: 2.5)
        XCTAssertEqual(fast.kokoroSpeed, 2.0, accuracy: 0.0001)
        XCTAssertEqual(fast.timePitchRate, 1.25, accuracy: 0.0001)
        XCTAssertTrue(fast.needsTimePitch)

        let triple = KokoroSpeedPlan(rate: 3.0)
        XCTAssertEqual(triple.kokoroSpeed, 2.0, accuracy: 0.0001)
        XCTAssertEqual(triple.timePitchRate, 1.5, accuracy: 0.0001)
    }

    func testAlignerExactOneToOneWordSpansAndMultiChunkBosEos() {
        let ids: [Int32] = [0, 50, 51, 16, 60, 61, 0, 0, 70, 71, 0]
        let durs: [Int32] = [2, 4, 4, 2, 6, 4, 2, 2, 6, 6, 2]
        let timings = KokoroWordAligner.align(
            sliceText: "Hello world again.",
            sliceUTF16Offset: 10,
            rawAudioDuration: 2.0,
            inputIds: ids,
            predictedDurations: durs,
            normalizedText: "Hello world again."
        )

        XCTAssertEqual(timings.count, 3)
        XCTAssertEqual(timings[0].utf16Range, TTSUTF16Range(location: 10, length: 5))
        XCTAssertEqual(timings[0].startTime, 0.10, accuracy: 0.001)
        XCTAssertEqual(timings[0].endTime, 0.50, accuracy: 0.001)

        XCTAssertEqual(timings[1].utf16Range, TTSUTF16Range(location: 16, length: 5))
        XCTAssertEqual(timings[1].startTime, 0.60, accuracy: 0.001)
        XCTAssertEqual(timings[1].endTime, 1.10, accuracy: 0.001)

        XCTAssertEqual(timings[2].utf16Range, TTSUTF16Range(location: 22, length: 5))
        XCTAssertEqual(timings[2].startTime, 1.30, accuracy: 0.001)
        XCTAssertEqual(timings[2].endTime, 1.90, accuracy: 0.001)
    }

    func testAlignerDropsLeadingQuotesAndBracketsEmittedAsSeparateTokens() {
        // Dialogue with standalone leading “ (14) and ( (12) tokens plus trailing , (3) ” (15) ) (13) . (4):
        // BOS(2) + “ (2) + sp(1) + Hello(10) + sp(1) + world(10) + ,(2) + ”(2) + sp(1) + ((2) + sp(1) + she(6) + )(2) + sp(1) + said(15) + .(2) + EOS(0) = 60 frames over 6.0s (0.1s/frame)
        let ids: [Int32] = [0, 14, 16, 50, 16, 60, 3, 15, 16, 12, 16, 70, 13, 16, 80, 4, 0]
        let durs: [Int32] = [2, 2, 1, 10, 1, 10, 2, 2, 1, 2, 1, 6, 2, 1, 15, 2, 0]
        let text = "\u{201C}Hello world,\u{201D} (she) said."
        let timings = KokoroWordAligner.align(
            sliceText: text,
            sliceUTF16Offset: 0,
            rawAudioDuration: 6.0,
            inputIds: ids,
            predictedDurations: durs,
            normalizedText: text
        )

        XCTAssertEqual(timings.count, 4)
        // Hello: frames 5..15 -> 0.5..1.5 (NOT shifted onto the opening quote!)
        XCTAssertEqual(timings[0].startTime, 0.50, accuracy: 0.001)
        XCTAssertEqual(timings[0].endTime, 1.50, accuracy: 0.001)
        // world: frames 16..26 -> 1.6..2.6 (trailing comma/quote excluded from end)
        XCTAssertEqual(timings[1].startTime, 1.60, accuracy: 0.001)
        XCTAssertEqual(timings[1].endTime, 2.60, accuracy: 0.001)
        // she: frames 34..40 -> 3.4..4.0 (standalone opening paren ignored!)
        XCTAssertEqual(timings[2].startTime, 3.40, accuracy: 0.001)
        XCTAssertEqual(timings[2].endTime, 4.00, accuracy: 0.001)
        // said: frames 43..58 -> 4.3..5.8 (exact non-proportional timing: 1.5s vs 0.6s for "she")
        XCTAssertEqual(timings[3].startTime, 4.30, accuracy: 0.001)
        XCTAssertEqual(timings[3].endTime, 5.80, accuracy: 0.001)
    }

    func testAlignerHandlesNormalizedExpansionLikeCurrencyAndNumbers() {
        let ids: [Int32] = [0, 41, 16, 42, 16, 43, 16, 44, 16, 45, 0]
        let durs: [Int32] = [0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0]
        let timings = KokoroWordAligner.align(
            sliceText: "Costs $45 today.",
            sliceUTF16Offset: 0,
            rawAudioDuration: 5.0,
            inputIds: ids,
            predictedDurations: durs,
            normalizedText: "Costs forty five dollars today."
        )

        XCTAssertEqual(timings.count, 3)
        XCTAssertEqual(timings[0].startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(timings[0].endTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(timings[1].startTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(timings[1].endTime, 4.0, accuracy: 0.001)
        XCTAssertEqual(timings[2].startTime, 4.0, accuracy: 0.001)
        XCTAssertEqual(timings[2].endTime, 5.0, accuracy: 0.001)
    }

    func testAlignerCountMismatchWithoutNormalizedTextAndSurrogatePairs() {
        // Emoji "🚀" is 2 UTF-16 code units; "hello" starts at UTF-16 offset 3 within slice, +5 base = 8.
        let ids: [Int32] = [0, 41, 16, 42, 16, 43, 0]
        let durs: [Int32] = [10, 10, 0, 10, 0, 10, 10] // spoken spans cover 1.0..4.0 out of 5.0s
        let timings = KokoroWordAligner.align(
            sliceText: "🚀 hello world",
            sliceUTF16Offset: 5,
            rawAudioDuration: 5.0,
            inputIds: ids,
            predictedDurations: durs,
            normalizedText: nil
        )
        XCTAssertEqual(timings.count, 2)
        XCTAssertEqual(timings[0].utf16Range, TTSUTF16Range(location: 8, length: 5))
        XCTAssertEqual(timings[1].utf16Range, TTSUTF16Range(location: 14, length: 5))
        // Proportional across spoken bounds [1.0, 4.0] for two equal-length words -> 1.0..2.5 and 2.5..4.0
        XCTAssertEqual(timings[0].startTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(timings[0].endTime, 2.5, accuracy: 0.001)
        XCTAssertEqual(timings[1].startTime, 2.5, accuracy: 0.001)
        XCTAssertEqual(timings[1].endTime, 4.0, accuracy: 0.001)
    }

    func testAlignerDegradesGracefullyOnZeroDurationMismatchedArraysAndPunctuationOnly() {
        let zeroDur = KokoroWordAligner.align(
            sliceText: "One two",
            sliceUTF16Offset: 2,
            rawAudioDuration: 0,
            inputIds: [0, 50, 0],
            predictedDurations: [1, 2, 1]
        )
        XCTAssertEqual(zeroDur.count, 2)
        XCTAssertEqual(zeroDur[0].startTime, 0)
        XCTAssertEqual(zeroDur[1].endTime, 0)

        let mismatched = KokoroWordAligner.align(
            sliceText: "Hi there!",
            sliceUTF16Offset: 0,
            rawAudioDuration: 1.4,
            inputIds: [0, 50, 0],
            predictedDurations: [1, 2]
        )
        XCTAssertEqual(mismatched.count, 2)
        XCTAssertEqual(mismatched[0].startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(mismatched[0].endTime, 0.4, accuracy: 0.001)
        XCTAssertEqual(mismatched[1].startTime, 0.4, accuracy: 0.001)
        XCTAssertEqual(mismatched[1].endTime, 1.4, accuracy: 0.001)

        // Punctuation-only tokens yield empty spoken spans and fall back cleanly.
        let punctOnlySpans = KokoroWordAligner.spokenWordSpans(
            inputIds: [0, 14, 16, 15, 0],
            predictedDurations: [1, 2, 1, 2, 1],
            rawAudioDuration: 1.0
        )
        XCTAssertTrue(punctOnlySpans.isEmpty)
    }

    func testAlignerFallbackWhenDurationsMissingAndActiveWordBinarySearch() {
        let timings = KokoroWordAligner.align(
            sliceText: "Hi there!",
            sliceUTF16Offset: 4,
            rawAudioDuration: 1.4,
            inputIds: [],
            predictedDurations: []
        )
        XCTAssertEqual(timings.count, 2)
        XCTAssertEqual(timings[0].startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(timings[0].endTime, 0.4, accuracy: 0.001)
        XCTAssertEqual(timings[1].startTime, 0.4, accuracy: 0.001)
        XCTAssertEqual(timings[1].endTime, 1.4, accuracy: 0.001)

        XCTAssertEqual(KokoroWordAligner.activeWordIndex(at: 0.0, in: timings, leadSeconds: 0), 0)
        XCTAssertEqual(KokoroWordAligner.activeWordIndex(at: 0.39, in: timings, leadSeconds: 0.02), 1)
        XCTAssertEqual(KokoroWordAligner.activeWordIndex(at: 1.35, in: timings, leadSeconds: 0), 1)
    }
}
