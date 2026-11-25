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
