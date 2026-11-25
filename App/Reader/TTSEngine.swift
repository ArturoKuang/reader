import AVFoundation
import Foundation
import ReaderCore

extension Notification.Name {
    /// The player or Settings changed the saved speed or voice.
    static let ttsSettingsDidChange = Notification.Name("reader.ttsSettingsDidChange")
}

/// Where playback should begin.
enum TTSStartAnchor {
    case viewport
    /// `pageOrSection` is the 0-based locator index preferred among repeated matches.
    case selection(text: String, prefix: String, suffix: String, pageOrSection: Int?)
    case location(chapterIndex: Int, segmentIndex: Int, utf16Offset: Int)
}

/// Everything the player shows.
struct TTSEngineState: Equatable {
    var isPresented = false
    var status = TTSPlaybackState.idle
    var chapterTitle = ""
    /// Transient loading status shown while Kokoro downloads or warms up.
    var statusDetail: String?
    /// Position in the current chapter, in 1.0x seconds, so it does not jump with speed.
    var elapsed: TimeInterval = 0
    var duration: TimeInterval = 0
    var rate = 1.0
    var voiceIdentifier: String?
    var autoScrollEnabled = true

    var progress: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }
}

/// Drives on-device Kokoro-82M synthesis (`KokoroEngineService`) and `AVAudioEngine`
/// playback through a document's chapter plans with gapless lookahead prefetching
/// and latency-compensated, sample-accurate word highlighting.
@MainActor
final class TTSEngine {
    static let bottomInset: CGFloat = 136

    weak var bridge: TTSDocumentBridge?
    var onStateChange: ((TTSEngineState) -> Void)?
    var onToast: ((String) -> Void)?

    private(set) var state = TTSEngineState()
    private(set) var generation: UInt64 = 0
    private(set) var chapters: [TTSChapterPlan] = []
    private(set) var chapterIndex = 0
    private(set) var segmentIndex = 0
    /// Start of the spoken word within the current segment.
    private(set) var utf16Offset = 0
    private(set) var reachedEnd = false
    private(set) var isLoading = false
    /// True while the player is open or still preparing to open.
    var isActive: Bool { state.isPresented || isLoading }

    private struct PrefetchKey: Hashable, Sendable {
        let chapter: Int
        let segment: Int
        let offset: Int
        let voiceID: String
        let rateHundredths: Int
    }

    private let loadSettings: () -> AISettings
    private let saveSettings: (AISettings) -> Void
    private let volume: Float
    private let service: KokoroEngineService

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioGraphAttached = false
    private var configuredSampleRate: Int?
    private var configChangeObserver: NSObjectProtocol?
    private var statusObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    private var playbackToken: UInt64 = 0
    private var prefetchGeneration: UInt64 = 0
    private var activeSynthesisTask: Task<Void, Never>?
    private var prefetchDriverTask: Task<Void, Never>?
    private var activePrefetchKey: PrefetchKey?
    private var activePrefetchTask: Task<KokoroSynthesizedClip, Error>?
    private var prefetchCache: [PrefetchKey: KokoroSynthesizedClip] = [:]
    private var prefetchOrder: [PrefetchKey] = []

    private var currentClip: KokoroSynthesizedClip?
    private var currentSliceStartOffset = 0
    private var activeTimingIndex: Int?
    private var wordRange: NSRange?
    private var hasScheduledBuffer = false
    private var isBufferPaused = false
    private var finishedWhilePaused = false
    private var needsSynthesisOnResume = false
    private var syncTimer: Timer?

    init(
        loadSettings: @escaping () -> AISettings = SettingsStore.load,
        saveSettings: @escaping (AISettings) -> Void = SettingsStore.save,
        volume: Float = 1,
        service: KokoroEngineService = .shared
    ) {
        self.loadSettings = loadSettings
        self.saveSettings = saveSettings
        self.volume = volume
        self.service = service

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAudioConfigurationChange()
            }
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .kokoroStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncStatusDetailIfPreparing()
            }
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .ttsSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as AnyObject?) !== self else { return }
                self.applyExternalSettingsChange()
            }
        }
    }

    deinit {
        syncTimer?.invalidate()
        activeSynthesisTask?.cancel()
        prefetchDriverTask?.cancel()
        activePrefetchTask?.cancel()
        if let configChangeObserver { NotificationCenter.default.removeObserver(configChangeObserver) }
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        playerNode.stop()
        audioEngine.stop()
    }

    // MARK: - Session

    /// Opens the player at `anchor`, or jumps there if it is already open.
    func open(from anchor: TTSStartAnchor) {
        if state.isPresented {
            state.autoScrollEnabled = true
            start(from: anchor, refreshViewport: true)
            return
        }
        guard let bridge else {
            onToast?("Read Aloud isn't available for this document yet")
            return
        }
        // Start warming the cached Core ML model in parallel while chapters are extracted.
        let preferredVoice = loadSettings().ttsVoiceIdentifier
        let svc = service
        Task { await svc.prewarmIfCached(preferredVoiceID: preferredVoice) }

        generation &+= 1
        let request = generation
        isLoading = true
        bridge.buildTTSChapters { [weak self] plans in
            guard let self, self.isLoading, self.generation == request else { return }
            self.isLoading = false
            self.present(plans, from: anchor)
        }
    }

    private func present(_ plans: [TTSChapterPlan], from anchor: TTSStartAnchor) {
        guard plans.contains(where: { !$0.segments.isEmpty }) else {
            onToast?("No readable text in this document")
            publish()
            return
        }
        let settings = loadSettings()
        chapters = plans
        clearPrefetchCache()
        let resolvedVoice = KokoroVoiceCatalog.resolve(settings.ttsVoiceIdentifier).id
        state = TTSEngineState(
            isPresented: true,
            rate: TTSRateMapper.clampedMultiplier(settings.ttsRateMultiplier),
            voiceIdentifier: resolvedVoice
        )
        bridge?.onManualScrollDuringTTS = { [weak self] in self?.userDidManuallyScroll() }
        bridge?.setTTSBottomInset(Self.bottomInset)
        start(from: anchor)
    }

    private func start(from anchor: TTSStartAnchor, refreshViewport: Bool = false) {
        switch anchor {
        case .location(let chapter, let segment, let offset):
            speakFrom(chapterIndex: chapter, segmentIndex: segment, utf16Offset: offset)
        case .selection(let text, let prefix, let suffix, let pageOrSection):
            let match = TTSTextPlanner.findStartSegment(
                matchingQuote: text, prefix: prefix, suffix: suffix, preferredPageOrSection: pageOrSection, in: chapters
            )
            guard let target = match?.target else { return start(from: .viewport, refreshViewport: refreshViewport) }
            speakFrom(chapterIndex: target.chapterIndex, segmentIndex: target.segmentIndex, utf16Offset: target.charOffset)
        case .viewport:
            guard refreshViewport, let bridge else {
                let top = bridge?.currentTTSViewportStart(in: chapters)
                speakFrom(chapterIndex: top?.chapterIndex ?? 0, segmentIndex: top?.segmentIndex ?? 0, utf16Offset: top?.utf16Offset ?? 0)
                return
            }
            cancelSpeech(cancelPrefetch: true)
            stopSyncTimer()
            needsSynthesisOnResume = true
            let request = generation
            bridge.resolveCurrentTTSViewportStart(in: chapters) { [weak self] top in
                guard let self, self.generation == request, self.state.isPresented else { return }
                self.speakFrom(chapterIndex: top.chapterIndex, segmentIndex: top.segmentIndex, utf16Offset: top.utf16Offset)
            }
        }
    }

    /// Closes the player and silences speech.
    func stop() {
        cancelSpeech(cancelPrefetch: true)
        stopSyncTimer()
        clearPrefetchCache()
        if audioEngine.isRunning { audioEngine.stop() }
        isLoading = false
        guard state.isPresented else { return }
        bridge?.clearTTSHighlight()
        bridge?.setTTSBottomInset(0)
        bridge?.onManualScrollDuringTTS = nil
        chapters = []
        wordRange = nil
        reachedEnd = false
        finishedWhilePaused = false
        needsSynthesisOnResume = false
        state = TTSEngineState(rate: state.rate, voiceIdentifier: state.voiceIdentifier)
        publish()
    }

    // MARK: - Transport

    func speakFrom(chapterIndex: Int, segmentIndex: Int, utf16Offset: Int) {
        move(chapter: chapterIndex, segment: segmentIndex, offset: utf16Offset, play: true, preservePrefetch: false)
    }

    func togglePlayPause() {
        if state.status == .playing { pause() } else { resume() }
    }

    func pause() {
        guard state.isPresented, state.status == .playing else { return }
        refreshFromPlaybackClock(forceHighlight: false)
        state.status = .paused
        state.statusDetail = nil
        stopSyncTimer()
        if hasScheduledBuffer {
            playerNode.pause()
            isBufferPaused = true
        } else {
            cancelSpeech(cancelPrefetch: true)
            needsSynthesisOnResume = true
        }
        publish()
    }

    func resume() {
        guard state.isPresented, state.status == .paused else { return }
        if reachedEnd {
            speakFrom(chapterIndex: chapterIndex, segmentIndex: 0, utf16Offset: 0)
            return
        }
        if finishedWhilePaused {
            finishedWhilePaused = false
            advanceAfterCurrentSegment()
            return
        }
        if hasScheduledBuffer, isBufferPaused, !needsSynthesisOnResume, currentClip != nil {
            do {
                if !audioEngine.isRunning { try audioEngine.start() }
                playerNode.play()
                isBufferPaused = false
                state.status = .playing
                startSyncTimer()
                publish()
                schedulePrefetch(afterChapter: chapterIndex, segment: segmentIndex)
                return
            } catch {
                needsSynthesisOnResume = true
            }
        }
        speakFrom(chapterIndex: chapterIndex, segmentIndex: segmentIndex, utf16Offset: utf16Offset)
    }

    /// Skips wall-clock seconds at the current speed.
    func skip(bySeconds delta: TimeInterval) {
        guard state.isPresented, let target = TTSTimeEstimator.skip(
            bySeconds: delta, chapterIndex: chapterIndex, segmentIndex: segmentIndex,
            charOffset: utf16Offset, rate: state.rate, in: chapters
        ) else { return }
        if delta > 0, target.reachedEnd, target.chapterIndex == chapters.count - 1 {
            finishAtEnd()
            return
        }
        move(to: target)
    }

    /// Scrubber position `0...1` within the current chapter.
    func seek(toFraction fraction: Double) {
        guard state.isPresented, chapters.indices.contains(chapterIndex) else { return }
        move(to: TTSTimeEstimator.seek(toFraction: fraction, in: chapters[chapterIndex]))
    }

    private func move(to target: TTSSeekTarget) {
        move(
            chapter: target.chapterIndex,
            segment: target.segmentIndex,
            offset: target.charOffset,
            play: state.status == .playing,
            preservePrefetch: false
        )
    }

    // MARK: - Settings

    func setRateMultiplier(_ multiplier: Double) {
        let rate = TTSRateMapper.clampedMultiplier(multiplier)
        guard rate != state.rate else { return }
        refreshFromPlaybackClock(forceHighlight: false)
        state.rate = rate
        clearPrefetchCache()
        persist { $0.ttsRateMultiplier = rate }
        restartAtCurrentWord()
    }

    func setVoiceIdentifier(_ identifier: String?) {
        let resolved = KokoroVoiceCatalog.resolve(identifier).id
        guard resolved != state.voiceIdentifier else { return }
        state.voiceIdentifier = resolved
        clearPrefetchCache()
        persist { $0.ttsVoiceIdentifier = resolved }
        restartAtCurrentWord()
    }

    private func applyExternalSettingsChange() {
        let saved = loadSettings()
        let rate = TTSRateMapper.clampedMultiplier(saved.ttsRateMultiplier)
        let voice = KokoroVoiceCatalog.resolve(saved.ttsVoiceIdentifier).id
        var changed = false
        if abs(rate - state.rate) > 0.0001 {
            refreshFromPlaybackClock(forceHighlight: false)
            state.rate = rate
            changed = true
        }
        if voice != state.voiceIdentifier {
            state.voiceIdentifier = voice
            changed = true
        }
        guard changed else { return }
        clearPrefetchCache()
        restartAtCurrentWord()
    }

    private func persist(_ change: (inout AISettings) -> Void) {
        var settings = loadSettings()
        change(&settings)
        saveSettings(settings)
        NotificationCenter.default.post(name: .ttsSettingsDidChange, object: self)
    }

    private func restartAtCurrentWord() {
        guard state.isPresented, !reachedEnd else {
            publish()
            return
        }
        move(
            chapter: chapterIndex,
            segment: segmentIndex,
            offset: utf16Offset,
            play: state.status == .playing,
            preservePrefetch: false
        )
    }

    // MARK: - Follow text

    func setAutoScroll(_ enabled: Bool) {
        guard state.isPresented else { return }
        state.autoScrollEnabled = enabled
        if enabled { bridge?.scrollToActiveTTSHighlight(animated: true) }
        publish()
    }

    func userDidManuallyScroll() {
        guard state.isPresented, state.autoScrollEnabled else { return }
        state.autoScrollEnabled = false
        onToast?("Follow-text paused · Click ≡ to re-center")
        publish()
    }

    // MARK: - Queue & Synthesis

    private var activeVoiceID: String {
        KokoroVoiceCatalog.resolve(state.voiceIdentifier).id
    }

    private func prefetchKey(chapter: Int, segment: Int, offset: Int) -> PrefetchKey {
        PrefetchKey(
            chapter: chapter,
            segment: segment,
            offset: offset,
            voiceID: activeVoiceID,
            rateHundredths: Int((state.rate * 100).rounded())
        )
    }

    private func cancelPrefetchTasks() {
        prefetchGeneration &+= 1
        prefetchDriverTask?.cancel()
        prefetchDriverTask = nil
        activePrefetchTask?.cancel()
        activePrefetchTask = nil
        activePrefetchKey = nil
    }

    private func cancelSpeech(cancelPrefetch: Bool) {
        generation &+= 1
        playbackToken &+= 1
        activeSynthesisTask?.cancel()
        activeSynthesisTask = nil
        if cancelPrefetch {
            cancelPrefetchTasks()
        }
        playerNode.stop()
        currentClip = nil
        activeTimingIndex = nil
        hasScheduledBuffer = false
        isBufferPaused = false
        finishedWhilePaused = false
        state.statusDetail = nil
    }

    private func clearPrefetchCache() {
        cancelPrefetchTasks()
        prefetchCache.removeAll()
        prefetchOrder.removeAll()
    }

    private func storePrefetch(_ clip: KokoroSynthesizedClip, for key: PrefetchKey) {
        if prefetchCache[key] == nil {
            prefetchOrder.append(key)
        }
        prefetchCache[key] = clip
        while prefetchOrder.count > 4 {
            let evicted = prefetchOrder.removeFirst()
            prefetchCache.removeValue(forKey: evicted)
        }
    }

    /// The first position at or after the request that still has something to say.
    private func speakablePosition(chapter: Int, segment: Int, offset: Int) -> (chapter: Int, segment: Int, offset: Int)? {
        var chapter = max(chapter, 0)
        var segment = max(segment, 0)
        var offset = max(offset, 0)
        while chapter < chapters.count {
            let segments = chapters[chapter].segments
            while segment < segments.count {
                let text = segments[segment].text as NSString
                if offset < text.length {
                    let start = text.rangeOfComposedCharacterSequence(at: offset).location
                    let remaining = text.substring(from: start)
                    if remaining.contains(where: { $0.isLetter || $0.isNumber }) {
                        return (chapter, segment, start)
                    }
                }
                segment += 1
                offset = 0
            }
            chapter += 1
            segment = 0
            offset = 0
        }
        return nil
    }

    private func move(chapter: Int, segment: Int, offset: Int, play: Bool, preservePrefetch: Bool) {
        guard state.isPresented else { return }
        cancelSpeech(cancelPrefetch: !preservePrefetch)
        guard let position = speakablePosition(chapter: chapter, segment: segment, offset: offset) else {
            finishAtEnd()
            return
        }
        chapterIndex = position.chapter
        segmentIndex = position.segment
        utf16Offset = position.offset
        currentSliceStartOffset = position.offset
        reachedEnd = false
        let current = chapters[chapterIndex].segments[segmentIndex]
        wordRange = current.wordRanges.first { $0.location <= utf16Offset && utf16Offset < $0.end }?.nsRange
            ?? (utf16Offset == 0 ? current.wordRanges.first?.nsRange : nil)
        state.status = play ? .playing : .paused
        needsSynthesisOnResume = !play
        resetElapsed()
        highlight()
        if play {
            beginSynthesizingCurrentSegment()
        } else {
            stopSyncTimer()
        }
        publish()
    }

    private func beginSynthesizingCurrentSegment() {
        let gen = generation
        let chapter = chapterIndex
        let segment = segmentIndex
        let sliceOffset = utf16Offset
        let segmentModel = chapters[chapter].segments[segment]
        let sliceText = (segmentModel.text as NSString).substring(from: sliceOffset)
        let key = prefetchKey(chapter: chapter, segment: segment, offset: sliceOffset)

        // 1. Instant hit from completed lookahead cache.
        if let cached = prefetchCache.removeValue(forKey: key) {
            prefetchOrder.removeAll { $0 == key }
            playClip(cached, generation: gen)
            return
        }

        // 2. Join already-running prefetch for this exact key instead of discarding partial work.
        let joinedTask: Task<KokoroSynthesizedClip, Error>?
        if activePrefetchKey == key, let inFlight = activePrefetchTask {
            joinedTask = inFlight
            activePrefetchKey = nil
            activePrefetchTask = nil
        } else {
            // Unrelated prefetch shouldn't delay the active segment.
            cancelPrefetchTasks()
            joinedTask = nil
        }

        let voiceID = activeVoiceID
        let rate = state.rate
        let svc = service

        activeSynthesisTask = Task { [weak self] in
            let initialStatus = await svc.currentStatus()
            if case .ready = initialStatus {
                // Already warm — avoid banner flicker.
            } else {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == gen,
                          self.state.isPresented, self.state.status == .playing else { return }
                    self.state.statusDetail = Self.loadingBanner(for: initialStatus)
                    self.publish()
                }
            }

            do {
                let clip: KokoroSynthesizedClip
                if let joinedTask {
                    clip = try await joinedTask.value
                } else {
                    clip = try await svc.synthesize(
                        sliceText: sliceText,
                        sliceUTF16Offset: sliceOffset,
                        voiceID: voiceID,
                        rate: rate
                    )
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == gen,
                          self.state.isPresented, self.state.status == .playing else { return }
                    self.activeSynthesisTask = nil
                    self.playClip(clip, generation: gen)
                }
            } catch is CancellationError {
                return
            } catch let error as KokoroServiceError {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == gen,
                          self.state.isPresented, self.state.status == .playing else { return }
                    self.activeSynthesisTask = nil
                    switch error {
                    case .unpronounceableText:
                        let length = self.chapters[self.chapterIndex].segments[self.segmentIndex].utf16Length
                        self.move(chapter: self.chapterIndex, segment: self.segmentIndex, offset: length, play: true, preservePrefetch: true)
                    case .modelUnavailable(let detail):
                        self.handleSynthesisFailure(detail)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == gen,
                          self.state.isPresented, self.state.status == .playing else { return }
                    self.activeSynthesisTask = nil
                    self.handleSynthesisFailure(error.localizedDescription)
                }
            }
        }
    }

    private func handleSynthesisFailure(_ detail: String) {
        state.status = .paused
        state.statusDetail = nil
        needsSynthesisOnResume = true
        stopSyncTimer()
        onToast?("Kokoro TTS unavailable: \(detail)")
        publish()
    }

    private static func loadingBanner(for status: KokoroModelStatus) -> String {
        switch status {
        case .preparing(let text): return text
        case .notDownloaded: return "Downloading Kokoro voice model…"
        case .cached: return "Loading Kokoro voice…"
        case .ready: return ""
        case .failed: return "Retrying Kokoro voice…"
        }
    }

    private func syncStatusDetailIfPreparing() {
        guard state.isPresented, state.status == .playing, activeSynthesisTask != nil, !hasScheduledBuffer else { return }
        let gen = generation
        let svc = service
        Task { [weak self] in
            let current = await svc.currentStatus()
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen, self.state.isPresented,
                      self.state.status == .playing, self.activeSynthesisTask != nil,
                      !self.hasScheduledBuffer else { return }
                if case .preparing(let message) = current {
                    self.state.statusDetail = message
                    self.publish()
                }
            }
        }
    }

    // MARK: - AVAudioEngine Playback

    private func ensureAudioGraph(sampleRate: Int) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
            throw KokoroServiceError.modelUnavailable("Invalid audio sample rate \(sampleRate)")
        }
        if !audioGraphAttached {
            audioEngine.attach(playerNode)
            audioEngine.attach(timePitch)
            audioGraphAttached = true
        }
        if configuredSampleRate != sampleRate {
            if audioEngine.isRunning { audioEngine.stop() }
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.disconnectNodeOutput(timePitch)
            audioEngine.connect(playerNode, to: timePitch, format: format)
            audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
            configuredSampleRate = sampleRate
            audioEngine.prepare()
        }
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        return format
    }

    private func playClip(_ clip: KokoroSynthesizedClip, generation gen: UInt64) {
        guard gen == generation, state.isPresented, state.status == .playing else { return }
        state.statusDetail = nil

        guard !clip.samples.isEmpty, clip.sampleRate > 0 else {
            advanceAfterCurrentSegment()
            return
        }

        do {
            let format = try ensureAudioGraph(sampleRate: clip.sampleRate)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(clip.samples.count)
            ) else {
                handleSynthesisFailure("Could not allocate audio buffer")
                return
            }
            buffer.frameLength = AVAudioFrameCount(clip.samples.count)
            if let channel = buffer.floatChannelData?[0] {
                clip.samples.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress {
                        channel.update(from: base, count: source.count)
                    }
                }
            }

            timePitch.pitch = 0
            timePitch.rate = clip.speedPlan.timePitchRate
            timePitch.bypass = !clip.speedPlan.needsTimePitch
            playerNode.volume = volume

            playbackToken &+= 1
            let token = playbackToken
            playerNode.stop()

            currentClip = clip
            activeTimingIndex = nil
            hasScheduledBuffer = true
            isBufferPaused = false
            finishedWhilePaused = false
            needsSynthesisOnResume = false

            if let firstWord = clip.timings.first {
                activeTimingIndex = 0
                utf16Offset = firstWord.utf16Range.location
                wordRange = firstWord.utf16Range.nsRange
                highlight()
            }

            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self,
                              gen == self.generation,
                              token == self.playbackToken,
                              self.state.isPresented else { return }
                        if self.state.status == .playing {
                            self.advanceAfterCurrentSegment()
                        } else if self.state.status == .paused {
                            self.hasScheduledBuffer = false
                            self.isBufferPaused = false
                            self.finishedWhilePaused = true
                        }
                    }
                }
            }
            playerNode.play()
            startSyncTimer()
            publish()
            schedulePrefetch(afterChapter: chapterIndex, segment: segmentIndex)
        } catch {
            handleSynthesisFailure(error.localizedDescription)
        }
    }

    private func advanceAfterCurrentSegment() {
        guard chapters.indices.contains(chapterIndex),
              chapters[chapterIndex].segments.indices.contains(segmentIndex) else {
            finishAtEnd()
            return
        }
        let length = chapters[chapterIndex].segments[segmentIndex].utf16Length
        move(chapter: chapterIndex, segment: segmentIndex, offset: length, play: true, preservePrefetch: true)
    }

    private func schedulePrefetch(afterChapter chapter: Int, segment: Int) {
        guard state.isPresented, state.status == .playing else { return }

        var targets: [(chapter: Int, segment: Int, offset: Int, text: String, key: PrefetchKey)] = []
        var cursorChapter = chapter
        var cursorSegment = segment
        for _ in 0..<2 {
            guard chapters.indices.contains(cursorChapter),
                  chapters[cursorChapter].segments.indices.contains(cursorSegment) else { break }
            let endOffset = chapters[cursorChapter].segments[cursorSegment].utf16Length
            guard let next = speakablePosition(chapter: cursorChapter, segment: cursorSegment, offset: endOffset) else { break }
            let key = prefetchKey(chapter: next.chapter, segment: next.segment, offset: next.offset)
            let text = (chapters[next.chapter].segments[next.segment].text as NSString).substring(from: next.offset)
            targets.append((next.chapter, next.segment, next.offset, text, key))
            cursorChapter = next.chapter
            cursorSegment = next.segment
        }

        let desiredKeys = Set(targets.map(\.key))
        // Keep any in-flight prefetch if it matches one of our desired lookahead segments.
        let preservedKey: PrefetchKey?
        let preservedTask: Task<KokoroSynthesizedClip, Error>?
        if let activeKey = activePrefetchKey, desiredKeys.contains(activeKey), let activeTask = activePrefetchTask {
            preservedKey = activeKey
            preservedTask = activeTask
            prefetchDriverTask?.cancel()
            prefetchDriverTask = nil
        } else {
            preservedKey = nil
            preservedTask = nil
            cancelPrefetchTasks()
        }

        let pendingTargets = targets.filter { prefetchCache[$0.key] == nil }
        guard !pendingTargets.isEmpty else { return }

        prefetchGeneration &+= 1
        let prefetchGen = prefetchGeneration
        let voiceID = activeVoiceID
        let rate = state.rate
        let svc = service

        prefetchDriverTask = Task { [weak self] in
            // Finish any preserved in-flight prefetch first so its work is stored and never wasted.
            if let preservedKey, let preservedTask {
                if let clip = try? await preservedTask.value, !Task.isCancelled {
                    await MainActor.run { [weak self] in
                        guard let self, self.prefetchGeneration == prefetchGen, self.state.isPresented else { return }
                        if self.activePrefetchKey == preservedKey {
                            self.activePrefetchKey = nil
                            self.activePrefetchTask = nil
                        }
                        self.storePrefetch(clip, for: preservedKey)
                    }
                }
            }

            for target in pendingTargets {
                guard !Task.isCancelled else { return }
                if target.key == preservedKey { continue }

                let alreadyCached = await MainActor.run { [weak self] () -> Bool in
                    guard let self, self.prefetchGeneration == prefetchGen, self.state.isPresented else { return true }
                    return self.prefetchCache[target.key] != nil
                }
                if alreadyCached { continue }

                let synthTask = Task<KokoroSynthesizedClip, Error> {
                    try await svc.synthesize(
                        sliceText: target.text,
                        sliceUTF16Offset: target.offset,
                        voiceID: voiceID,
                        rate: rate
                    )
                }

                let registered = await MainActor.run { [weak self] () -> Bool in
                    guard let self, self.prefetchGeneration == prefetchGen, self.state.isPresented else { return false }
                    self.activePrefetchKey = target.key
                    self.activePrefetchTask = synthTask
                    return true
                }
                guard registered else {
                    synthTask.cancel()
                    return
                }

                do {
                    let clip = try await synthTask.value
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        guard let self, self.prefetchGeneration == prefetchGen, self.state.isPresented else { return }
                        if self.activePrefetchKey == target.key {
                            self.activePrefetchKey = nil
                            self.activePrefetchTask = nil
                        }
                        self.storePrefetch(clip, for: target.key)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if self.activePrefetchKey == target.key {
                            self.activePrefetchKey = nil
                            self.activePrefetchTask = nil
                        }
                    }
                    if Task.isCancelled { return }
                }
            }
        }
    }

    private func handleAudioConfigurationChange() {
        configuredSampleRate = nil
        // If we are still downloading or synthesizing the first clip, let synthesis finish
        // and connect cleanly to the new output route when playClip runs.
        guard hasScheduledBuffer || currentClip != nil else { return }
        playbackToken &+= 1
        hasScheduledBuffer = false
        isBufferPaused = false
        finishedWhilePaused = false
        needsSynthesisOnResume = true
        stopSyncTimer()
        guard state.isPresented, state.status == .playing else { return }
        move(chapter: chapterIndex, segment: segmentIndex, offset: utf16Offset, play: true, preservePrefetch: true)
    }

    // MARK: - Word Highlight & Elapsed Time Sync

    private func currentBufferPlaybackTime() -> TimeInterval? {
        guard hasScheduledBuffer,
              let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid,
              playerTime.sampleRate > 0 else { return nil }
        let rawSec = Double(playerTime.sampleTime) / playerTime.sampleRate
        let outputLatency = max(0, audioEngine.outputNode.presentationLatency)
        let pitchLatency = timePitch.bypass ? 0 : max(0, timePitch.latency)
        let rateScale = timePitch.bypass ? 1.0 : Double(timePitch.rate)
        return max(0, rawSec - (outputLatency + pitchLatency) * rateScale)
    }

    private func startSyncTimer() {
        guard syncTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFromPlaybackClock(forceHighlight: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func refreshFromPlaybackClock(forceHighlight: Bool) {
        guard state.status == .playing,
              let clip = currentClip,
              chapters.indices.contains(chapterIndex),
              chapters[chapterIndex].segments.indices.contains(segmentIndex),
              let playbackSec = currentBufferPlaybackTime() else { return }

        var shouldPublish = false
        if let idx = KokoroWordAligner.activeWordIndex(at: playbackSec, in: clip.timings, leadSeconds: 0),
           forceHighlight || idx != activeTimingIndex {
            activeTimingIndex = idx
            let timing = clip.timings[idx]
            utf16Offset = timing.utf16Range.location
            wordRange = timing.utf16Range.nsRange
            highlight()
            shouldPublish = true
        }

        let chapter = chapters[chapterIndex]
        let segment = chapter.segments[segmentIndex]
        let startBase = chapter.baseTime(segmentIndex: segmentIndex, utf16Offset: currentSliceStartOffset)
        let endBase = chapter.baseTime(segmentIndex: segmentIndex, utf16Offset: segment.utf16Length)
        let duration = max(clip.rawAudioDuration, 0.001)
        let fraction = min(max(playbackSec / duration, 0), 1)
        let projected = startBase + fraction * max(endBase - startBase, 0)
        if abs(projected - state.elapsed) >= 0.05 || shouldPublish {
            state.elapsed = max(state.elapsed, projected)
            shouldPublish = true
        }
        if shouldPublish { publish() }
    }

    private func resetElapsed() {
        guard chapters.indices.contains(chapterIndex) else { return }
        state.elapsed = chapters[chapterIndex].baseTime(segmentIndex: segmentIndex, utf16Offset: utf16Offset)
    }

    /// Stops at the end of the last chapter and leaves the player open.
    private func finishAtEnd() {
        cancelSpeech(cancelPrefetch: true)
        stopSyncTimer()
        guard let last = chapters.lastIndex(where: { !$0.segments.isEmpty }) else { return }
        chapterIndex = last
        segmentIndex = chapters[last].segments.count - 1
        utf16Offset = chapters[last].segments[segmentIndex].utf16Length
        wordRange = nil
        reachedEnd = true
        needsSynthesisOnResume = true
        state.status = .paused
        resetElapsed()
        bridge?.clearTTSHighlight()
        publish()
    }

    private func highlight() {
        guard chapters.indices.contains(chapterIndex), chapters[chapterIndex].segments.indices.contains(segmentIndex) else { return }
        let chapter = chapters[chapterIndex]
        bridge?.applyTTSHighlight(
            chapter: chapter, segment: chapter.segments[segmentIndex],
            wordRangeInSegment: wordRange, autoScroll: state.autoScrollEnabled
        )
    }

    private func publish() {
        if state.isPresented, chapters.indices.contains(chapterIndex) {
            state.chapterTitle = chapters[chapterIndex].title
            state.duration = chapters[chapterIndex].estimatedDurationSec
        }
        onStateChange?(state)
    }
}

/// Kokoro-82M voice groups offered in the player menu and in Settings.
enum TTSVoiceCatalog {
    struct Group {
        var title: String
        var voices: [(identifier: String, label: String)]
    }

    static func groups() -> [Group] {
        KokoroVoiceCatalog.groups().map { group in
            Group(
                title: group.title,
                voices: group.voices.map { ($0.id, $0.label) }
            )
        }
    }
}
