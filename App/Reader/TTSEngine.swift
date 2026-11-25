import AVFoundation
import ReaderCore

extension Notification.Name {
    /// The player changed the saved speed or voice.
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
    /// Position in the current chapter, in 1.0x seconds, so it does not jump with speed.
    var elapsed: TimeInterval = 0
    var duration: TimeInterval = 0
    var rate = 1.0
    var voiceIdentifier: String?
    var autoScrollEnabled = true

    var progress: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }
}

/// `AVSpeechUtterance` carrying what its callbacks need to be placed or dropped.
private final class TaggedSpeechUtterance: AVSpeechUtterance {
    private(set) var generation: UInt64 = 0
    /// Where the spoken slice starts inside the segment text.
    private(set) var offset = 0

    convenience init(string: String, generation: UInt64, offset: Int) {
        self.init(string: string)
        self.generation = generation
        self.offset = offset
    }
}

/// Drives `AVSpeechSynthesizer` through a document's chapter plans.
///
/// Every change to what is queued bumps `generation`, and callbacks from an
/// utterance of an older generation are dropped. Only one utterance is queued at
/// a time; the next segment is enqueued when it finishes.
@MainActor
final class TTSEngine: NSObject, AVSpeechSynthesizerDelegate {
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

    private let loadSettings: () -> AISettings
    private let saveSettings: (AISettings) -> Void
    private let volume: Float
    private var synthesizer = AVSpeechSynthesizer()
    private var wordRange: NSRange?
    /// The queued utterance cannot be continued; resuming must enqueue a new one.
    private var needsReenqueue = false
    private var utteranceStarted = false
    private var ticker: Timer?
    private var tickAnchor = (base: 0.0, date: Date())
    private var warnedMissingVoice = false

    init(
        loadSettings: @escaping () -> AISettings = SettingsStore.load,
        saveSettings: @escaping (AISettings) -> Void = SettingsStore.save,
        volume: Float = 1
    ) {
        self.loadSettings = loadSettings
        self.saveSettings = saveSettings
        self.volume = volume
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        ticker?.invalidate()
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Session

    /// Opens the player at `anchor`, or jumps there if it is already open.
    func open(from anchor: TTSStartAnchor) {
        if state.isPresented {
            state.autoScrollEnabled = true
            // The reader may have scrolled since the plan was built.
            start(from: anchor, refreshViewport: true)
            return
        }
        guard let bridge else {
            onToast?("Read Aloud isn't available for this document yet")
            return
        }
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
        warnedMissingVoice = false
        state = TTSEngineState(
            isPresented: true,
            rate: TTSRateMapper.clampedMultiplier(settings.ttsRateMultiplier),
            voiceIdentifier: settings.ttsVoiceIdentifier
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
            // Silence the old position while the page answers. Any later transport
            // action bumps `generation` again and wins over this request.
            cancelSpeech()
            stopTicker()
            utteranceStarted = false
            needsReenqueue = true
            let request = generation
            bridge.resolveCurrentTTSViewportStart(in: chapters) { [weak self] top in
                guard let self, self.generation == request, self.state.isPresented else { return }
                self.speakFrom(chapterIndex: top.chapterIndex, segmentIndex: top.segmentIndex, utf16Offset: top.utf16Offset)
            }
        }
    }

    /// Closes the player and silences speech.
    func stop() {
        cancelSpeech()
        stopTicker()
        isLoading = false
        guard state.isPresented else { return }
        bridge?.clearTTSHighlight()
        bridge?.setTTSBottomInset(0)
        bridge?.onManualScrollDuringTTS = nil
        chapters = []
        wordRange = nil
        reachedEnd = false
        needsReenqueue = false
        state = TTSEngineState(rate: state.rate, voiceIdentifier: state.voiceIdentifier)
        publish()
    }

    // MARK: - Transport

    func speakFrom(chapterIndex: Int, segmentIndex: Int, utf16Offset: Int) {
        move(chapter: chapterIndex, segment: segmentIndex, offset: utf16Offset, play: true)
    }

    func togglePlayPause() {
        if state.status == .playing { pause() } else { resume() }
    }

    func pause() {
        guard state.isPresented, state.status == .playing else { return }
        refreshElapsed()
        state.status = .paused
        stopTicker()
        // Before an utterance starts, a pause can report success and still speak; drop it instead.
        if !utteranceStarted || !synthesizer.pauseSpeaking(at: .immediate) {
            cancelSpeech()
            needsReenqueue = true
        }
        publish()
    }

    func resume() {
        guard state.isPresented, state.status == .paused else { return }
        if reachedEnd {
            // Replay the chapter that just finished.
            speakFrom(chapterIndex: chapterIndex, segmentIndex: 0, utf16Offset: 0)
            return
        }
        guard !needsReenqueue, synthesizer.isPaused, synthesizer.continueSpeaking() else {
            speakFrom(chapterIndex: chapterIndex, segmentIndex: segmentIndex, utf16Offset: utf16Offset)
            return
        }
        state.status = .playing
        tickAnchor = (state.elapsed, Date())
        startTicker()
        publish()
        // Some systems accept `continueSpeaking` and then stay silent.
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.generation == expected, self.state.status == .playing else { return }
            guard self.synthesizer.isPaused || !self.synthesizer.isSpeaking else { return }
            self.speakFrom(chapterIndex: self.chapterIndex, segmentIndex: self.segmentIndex, utf16Offset: self.utf16Offset)
        }
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
        move(chapter: target.chapterIndex, segment: target.segmentIndex, offset: target.charOffset, play: state.status == .playing)
    }

    // MARK: - Settings

    func setRateMultiplier(_ multiplier: Double) {
        let rate = TTSRateMapper.clampedMultiplier(multiplier)
        guard rate != state.rate else { return }
        refreshElapsed()
        state.rate = rate
        persist { $0.ttsRateMultiplier = rate }
        restartAtCurrentWord()
    }

    func setVoiceIdentifier(_ identifier: String?) {
        guard identifier != state.voiceIdentifier else { return }
        state.voiceIdentifier = identifier
        warnedMissingVoice = false
        persist { $0.ttsVoiceIdentifier = identifier }
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
        move(chapter: chapterIndex, segment: segmentIndex, offset: utf16Offset, play: state.status == .playing)
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

    // MARK: - Queue

    private func cancelSpeech() {
        generation &+= 1
        if synthesizer.isPaused {
            // A synthesizer stopped while paused can swallow the next utterance.
            synthesizer.delegate = nil
            synthesizer.stopSpeaking(at: .immediate)
            synthesizer = AVSpeechSynthesizer()
            synthesizer.delegate = self
        } else {
            // A just-queued utterance can precede `isSpeaking`, so always stop.
            synthesizer.stopSpeaking(at: .immediate)
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
                    // Never cut a surrogate pair or grapheme cluster.
                    let start = text.rangeOfComposedCharacterSequence(at: offset).location
                    if !text.substring(from: start).allSatisfy(\.isWhitespace) { return (chapter, segment, start) }
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

    private func move(chapter: Int, segment: Int, offset: Int, play: Bool) {
        guard state.isPresented else { return }
        cancelSpeech()
        guard let position = speakablePosition(chapter: chapter, segment: segment, offset: offset) else {
            finishAtEnd()
            return
        }
        chapterIndex = position.chapter
        segmentIndex = position.segment
        utf16Offset = position.offset
        reachedEnd = false
        let current = chapters[chapterIndex].segments[segmentIndex]
        wordRange = utf16Offset == 0 ? nil : current.wordRanges.first { $0.location <= utf16Offset && utf16Offset < $0.end }?.nsRange
        state.status = play ? .playing : .paused
        needsReenqueue = !play
        resetElapsed()
        highlight()
        if play {
            enqueue(current)
            startTicker()
        } else {
            stopTicker()
        }
        publish()
    }

    private func enqueue(_ segment: TTSDocumentSegment) {
        let utterance = TaggedSpeechUtterance(
            string: (segment.text as NSString).substring(from: utf16Offset), generation: generation, offset: utf16Offset
        )
        utterance.rate = TTSRateMapper.avRate(
            for: state.rate,
            minRate: AVSpeechUtteranceMinimumSpeechRate,
            defaultRate: AVSpeechUtteranceDefaultSpeechRate,
            maxRate: AVSpeechUtteranceMaximumSpeechRate
        )
        utterance.volume = volume
        utterance.voice = resolvedVoice()
        utteranceStarted = false
        synthesizer.speak(utterance)
    }

    /// nil leaves the system default voice. A missing saved voice is kept in settings.
    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        guard let identifier = state.voiceIdentifier else { return nil }
        if let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        if !warnedMissingVoice {
            warnedMissingVoice = true
            onToast?("Selected voice unavailable — using system default")
        }
        return AVSpeechSynthesisVoice(language: nil)
    }

    /// Stops at the end of the last chapter and leaves the player open.
    private func finishAtEnd() {
        cancelSpeech()
        stopTicker()
        guard let last = chapters.lastIndex(where: { !$0.segments.isEmpty }) else { return }
        chapterIndex = last
        segmentIndex = chapters[last].segments.count - 1
        utf16Offset = chapters[last].segments[segmentIndex].utf16Length
        wordRange = nil
        reachedEnd = true
        needsReenqueue = true
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

    // MARK: - Elapsed time

    private func resetElapsed() {
        let base = chapters[chapterIndex].baseTime(segmentIndex: segmentIndex, utf16Offset: utf16Offset)
        state.elapsed = base
        tickAnchor = (base, Date())
    }

    /// Advances between word callbacks, but never past the next word.
    private func refreshElapsed() {
        guard state.status == .playing, chapters.indices.contains(chapterIndex),
              chapters[chapterIndex].segments.indices.contains(segmentIndex) else { return }
        let chapter = chapters[chapterIndex]
        let segment = chapter.segments[segmentIndex]
        let next = segment.wordRanges.first { $0.location > utf16Offset }?.location ?? segment.utf16Length
        let limit = chapter.baseTime(segmentIndex: segmentIndex, utf16Offset: next)
        let projected = tickAnchor.base + Date().timeIntervalSince(tickAnchor.date) * state.rate
        state.elapsed = max(state.elapsed, min(projected, limit))
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.state.elapsed
                self.refreshElapsed()
                if self.state.elapsed != before { self.publish() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    /// Hops to the main queue in arrival order and drops superseded utterances.
    private nonisolated func deliver(_ utterance: AVSpeechUtterance, _ body: @escaping @MainActor (TTSEngine, _ offset: Int) -> Void) {
        guard let tagged = utterance as? TaggedSpeechUtterance else { return }
        let (generation, offset) = (tagged.generation, tagged.offset)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.generation, self.state.isPresented else { return }
                body(self, offset)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        deliver(utterance) { engine, offset in engine.willSpeak(characterRange, offset: offset) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        deliver(utterance) { engine, _ in engine.utteranceStarted = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        deliver(utterance) { engine, _ in
            guard engine.state.status == .playing else { return }
            let length = engine.chapters[engine.chapterIndex].segments[engine.segmentIndex].utf16Length
            engine.move(chapter: engine.chapterIndex, segment: engine.segmentIndex, offset: length, play: true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Our own cancellations bump the generation first, so this one came from outside.
        deliver(utterance) { engine, _ in
            engine.state.status = .paused
            engine.needsReenqueue = true
            engine.stopTicker()
            engine.publish()
        }
    }

    private func willSpeak(_ range: NSRange, offset: Int) {
        let length = chapters[chapterIndex].segments[segmentIndex].utf16Length
        let location = offset + range.location
        guard state.status == .playing, range.location != NSNotFound, location < length else { return }
        utteranceStarted = true
        utf16Offset = location
        wordRange = NSRange(location: location, length: min(range.length, length - location))
        resetElapsed()
        highlight()
        publish()
    }
}

/// Installed voices offered in the player menu and in Settings.
enum TTSVoiceCatalog {
    struct Group {
        var title: String
        var voices: [(identifier: String, label: String)]
    }

    /// English and system-language voices, best quality first. `selected` is
    /// listed even when it falls outside that filter.
    static func groups(including selected: String? = nil) -> [Group] {
        let languages: Set<String> = ["en", String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))]
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            if voice.identifier == selected { return true }
            return languages.contains(String(voice.language.prefix(2)))
                && !voice.voiceTraits.contains(.isNoveltyVoice)
                && !voice.identifier.contains(".eloquence.")
        }
        let qualities: [(AVSpeechSynthesisVoiceQuality, String)] = [(.premium, "Premium"), (.enhanced, "Enhanced"), (.default, "Standard")]
        return qualities.compactMap { quality, title in
            let members = voices.filter { $0.quality == quality }
                .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
                .map { ($0.identifier, "\($0.name) — \(Locale.current.localizedString(forIdentifier: $0.language) ?? $0.language)") }
            return members.isEmpty ? nil : Group(title: title, voices: members)
        }
    }
}
