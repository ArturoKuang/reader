import Foundation
import ReaderCore
import ReaderKokoro

extension Notification.Name {
    /// Fired on the main queue whenever Kokoro's model readiness changes.
    static let kokoroStatusDidChange = Notification.Name("reader.kokoroStatusDidChange")
}

/// Readiness state of the on-device Kokoro-82M Core ML model.
enum KokoroModelStatus: Equatable, Sendable {
    case notDownloaded
    case cached
    case preparing(String)
    case ready
    case failed(String)

    var summaryText: String {
        switch self {
        case .notDownloaded: return "Downloads automatically on first Listen (~350 MB)"
        case .cached: return "Cached on disk — ready to load"
        case .preparing(let message): return message
        case .ready: return "Ready (Apple Neural Engine)"
        case .failed(let message): return "Error: \(message)"
        }
    }
}

/// Synthesized PCM audio clip with aligned word timings in raw buffer seconds.
struct KokoroSynthesizedClip: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let speedPlan: KokoroSpeedPlan
    let timings: [KokoroWordTiming]

    var rawAudioDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }
}

/// Errors classified so `TTSEngine` can skip unpronounceable punctuation segments
/// without aborting the entire playback session.
enum KokoroServiceError: LocalizedError {
    case unpronounceableText(String)
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unpronounceableText(let detail): return detail
        case .modelUnavailable(let detail): return detail
        }
    }
}

/// Shared actor owning the single on-device `KokoroAneManager` (Core ML ANE-v3)
/// across all open Reader windows.
actor KokoroEngineService {
    static let shared = KokoroEngineService()

    nonisolated static var modelsDirectory: URL {
        let url = URL(fileURLWithPath: AppPaths.support, isDirectory: true)
            .appendingPathComponent("KokoroModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// True when the ANE-v3 compiled Core ML bundles (with `coremldata.bin`) exist on disk.
    nonisolated static func isModelCachedOnDisk() -> Bool {
        let v3Root = modelsDirectory.appendingPathComponent("kokoro-82m-coreml/ANE-v3", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: v3Root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        var validBundles = 0
        for case let url as URL in enumerator {
            if url.pathExtension == "mlmodelc" {
                let dataFile = url.appendingPathComponent("coremldata.bin")
                if FileManager.default.fileExists(atPath: dataFile.path) {
                    validBundles += 1
                    if validBundles >= 10 { return true }
                }
                enumerator.skipDescendants()
            }
        }
        return false
    }

    private var manager: KokoroAneManager?
    private var initTask: Task<KokoroAneManager, Error>?
    private var status: KokoroModelStatus

    init() {
        self.status = Self.isModelCachedOnDisk() ? .cached : .notDownloaded
    }

    func currentStatus() -> KokoroModelStatus {
        status
    }

    /// Quietly warms up Core ML models in the background only if already downloaded on disk.
    func prewarmIfCached(preferredVoiceID: String?) {
        guard manager == nil, initTask == nil, Self.isModelCachedOnDisk() else { return }
        let voice = KokoroVoiceCatalog.resolve(preferredVoiceID).id
        Task {
            _ = try? await self.ensureReady(voiceID: voice)
        }
    }

    /// Downloads (if missing) and initializes the Kokoro-82M ANE-v3 pipeline.
    @discardableResult
    func ensureReady(voiceID: String) async throws -> KokoroAneManager {
        try Task.checkCancellation()
        let resolvedVoice = KokoroVoiceCatalog.resolve(voiceID).id
        if let manager {
            return manager
        }
        if let existing = initTask {
            let ready = try await existing.value
            try Task.checkCancellation()
            return ready
        }

        let cached = Self.isModelCachedOnDisk()
        updateStatus(.preparing(cached ? "Loading Kokoro voice…" : "Downloading Kokoro voice model…"))

        let directory = Self.modelsDirectory
        let task = Task<KokoroAneManager, Error> {
            let mgr = KokoroAneManager(
                variant: .english,
                defaultVoice: KokoroVoiceCatalog.defaultVoiceID,
                directory: directory,
                version: .v3
            )
            try await mgr.initialize(preloadVoices: [resolvedVoice])
            return mgr
        }
        initTask = task

        let result = await task.result
        initTask = nil

        switch result {
        case .success(let readyManager):
            manager = readyManager
            updateStatus(.ready)
            try Task.checkCancellation()
            return readyManager
        case .failure(let error):
            if error is CancellationError {
                updateStatus(Self.isModelCachedOnDisk() ? .cached : .notDownloaded)
                throw CancellationError()
            }
            let message = error.localizedDescription
            updateStatus(.failed(message))
            throw KokoroServiceError.modelUnavailable(message)
        }
    }

    /// Synthesizes a document slice with Kokoro-82M and aligns its predicted durations
    /// back onto UTF-16 word ranges in the owning segment.
    func synthesize(
        sliceText: String,
        sliceUTF16Offset: Int,
        voiceID: String,
        rate: Double
    ) async throws -> KokoroSynthesizedClip {
        try Task.checkCancellation()
        let resolvedVoice = KokoroVoiceCatalog.resolve(voiceID).id
        let mgr = try await ensureReady(voiceID: resolvedVoice)
        try Task.checkCancellation()

        let speedPlan = KokoroSpeedPlan(rate: rate)
        do {
            let result = try await mgr.synthesizeDetailed(
                text: sliceText,
                voice: resolvedVoice,
                speed: speedPlan.kokoroSpeed
            )
            try Task.checkCancellation()
            let timings = KokoroWordAligner.align(
                sliceText: sliceText,
                sliceUTF16Offset: sliceUTF16Offset,
                rawAudioDuration: result.durationSeconds,
                inputIds: result.inputIds,
                predictedDurations: result.predictedDurations,
                normalizedText: result.normalizedText
            )
            // FluidAudio ANE-v3 fast vocoder (<=200 frames) renders ~3.5 dB hotter than the base chain.
            // Attenuate fast-vocoder clips by -3.5 dB so short and long sentences play at uniform volume.
            let samples: [Float]
            if result.usedFastVocoder {
                let gain: Float = 0.6683439
                samples = result.samples.map { $0 * gain }
            } else {
                samples = result.samples
            }
            return KokoroSynthesizedClip(
                samples: samples,
                sampleRate: result.sampleRate,
                speedPlan: speedPlan,
                timings: timings
            )
        } catch let error as KokoroAneError {
            if case .inputProcessingFailed(let detail) = error {
                throw KokoroServiceError.unpronounceableText(detail)
            }
            throw error
        }
    }

    private func updateStatus(_ next: KokoroModelStatus) {
        guard status != next else { return }
        status = next
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .kokoroStatusDidChange, object: nil)
        }
    }
}
