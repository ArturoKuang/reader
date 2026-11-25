import AppKit
import QuartzCore
import ReaderCore

/// The pill's surface, chosen from the document theme rather than the system alone.
enum TTSPlayerTheme: Equatable {
    case light, dark, paper

    fileprivate var palette: TTSPlayerPalette {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
        }
        switch self {
        case .dark:
            return TTSPlayerPalette(
                tint: rgb(28, 28, 30, 0.76), border: rgb(255, 255, 255, 0.14), primary: rgb(245, 245, 247),
                secondary: rgb(235, 235, 245, 0.56), track: rgb(255, 255, 255, 0.20), hover: rgb(255, 255, 255, 0.11),
                shadow: 0.38
            )
        case .light:
            return TTSPlayerPalette(
                tint: rgb(248, 248, 250, 0.84), border: rgb(0, 0, 0, 0.10), primary: rgb(28, 28, 30),
                secondary: rgb(28, 28, 30, 0.54), track: rgb(0, 0, 0, 0.16), hover: rgb(0, 0, 0, 0.07),
                shadow: 0.18
            )
        case .paper:
            return TTSPlayerPalette(
                tint: rgb(249, 243, 230, 0.88), border: rgb(43, 33, 24, 0.12), primary: rgb(43, 33, 24),
                secondary: rgb(43, 33, 24, 0.56), track: rgb(43, 33, 24, 0.16), hover: rgb(43, 33, 24, 0.07),
                shadow: 0.18
            )
        }
    }
}

private struct TTSPlayerPalette {
    var tint: NSColor
    var border: NSColor
    var primary: NSColor
    var secondary: NSColor
    var track: NSColor
    var hover: NSColor
    var shadow: Float
}

/// The floating Read Aloud pill. It renders `TTSEngineState` and reports intents.
final class TTSPlayerView: NSView {
    static let height: CGFloat = 104
    static let cornerRadius: CGFloat = 26

    static func width(forPane paneWidth: CGFloat) -> CGFloat {
        min(444, max(288, paneWidth - 32))
    }

    var onClose: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onSkip: ((TimeInterval) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onSelectSpeed: ((Double) -> Void)?
    var onSelectVoice: ((String?) -> Void)?
    var onSetFollow: ((Bool) -> Void)?
    /// Shown when a chapter has no title.
    var fallbackTitle = ""

    private(set) var theme = TTSPlayerTheme.light
    private var state = TTSEngineState()

    private let effect = NSVisualEffectView()
    private let content = TTSPillContentView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let scrubber = TTSScrubberControl()
    private let closeButton = TTSPillButton(symbol: "xmark", pointSize: 12.5, weight: .semibold, radius: 14)
    private let backButton = TTSPillButton(symbol: "gobackward.15", pointSize: 15, weight: .medium, radius: 7)
    private let playButton = TTSPillButton(symbol: "play.fill", pointSize: 17, weight: .semibold, radius: 16)
    private let forwardButton = TTSPillButton(symbol: "goforward.15", pointSize: 15, weight: .medium, radius: 7)
    private let speedButton = TTSPillButton(symbol: nil, pointSize: 13, weight: .semibold, radius: 6)
    private let followButton = TTSPillButton(symbol: "text.alignleft", pointSize: 13, weight: .medium, radius: 7)

    override init(frame: NSRect) {
        super.init(frame: frame)
        TTSVoiceCatalog.prewarm()
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -6)

        // Blend with the document underneath, not with whatever is behind the window.
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        addSubview(effect)

        content.wantsLayer = true
        content.layer?.cornerRadius = Self.cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.borderWidth = 0.5
        effect.addSubview(content)

        titleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.alignment = .right

        let controls: [NSView] = [titleLabel, timeLabel, scrubber, closeButton, backButton, playButton, forwardButton, speedButton, followButton]
        controls.forEach(content.addSubview)

        closeButton.describe("Close Read Aloud (Esc)")
        backButton.describe("Back 15 seconds")
        forwardButton.describe("Forward 15 seconds")
        speedButton.describe("Playback speed & voice")

        for button in [closeButton, backButton, playButton, forwardButton, speedButton, followButton] {
            button.target = self
        }
        closeButton.action = #selector(closeClicked)
        backButton.action = #selector(backClicked)
        playButton.action = #selector(playClicked)
        forwardButton.action = #selector(forwardClicked)
        speedButton.action = #selector(speedClicked)
        followButton.action = #selector(followClicked)

        scrubber.onScrub = { [weak self] fraction in
            guard let self else { return }
            self.timeLabel.stringValue = TTSTimeEstimator.formatElapsed(fraction * self.state.duration)
            self.needsLayout = true
        }
        scrubber.onCommit = { [weak self] fraction in self?.onSeek?(fraction) }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Read Aloud player")
        apply(theme: .light)
        render(state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func render(_ state: TTSEngineState) {
        self.state = state
        let baseTitle = state.chapterTitle.isEmpty ? fallbackTitle : state.chapterTitle
        let title = (state.statusDetail?.isEmpty == false) ? state.statusDetail! : baseTitle
        titleLabel.stringValue = title
        titleLabel.toolTip = title
        scrubber.duration = state.duration
        if !scrubber.isDragging {
            scrubber.fraction = state.progress
            timeLabel.stringValue = TTSTimeEstimator.formatElapsed(state.elapsed)
        }
        let playing = state.status == .playing
        playButton.symbol = playing ? "pause.fill" : "play.fill"
        playButton.describe(playing ? "Pause" : "Play")
        speedButton.title = TTSRateMapper.formatMultiplier(state.rate)
        followButton.isOn = state.autoScrollEnabled
        followButton.contentAlpha = state.autoScrollEnabled ? 1 : 0.38
        followButton.describe(state.autoScrollEnabled ? "Turn off automatic scrolling" : "Turn on automatic scrolling")
        needsLayout = true
    }

    func apply(theme: TTSPlayerTheme) {
        self.theme = theme
        let palette = theme.palette
        appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        effect.material = theme == .dark ? .hudWindow : .popover
        content.layer?.backgroundColor = palette.tint.cgColor
        content.layer?.borderColor = palette.border.cgColor
        layer?.shadowOpacity = palette.shadow
        titleLabel.textColor = palette.primary
        timeLabel.textColor = palette.secondary
        scrubber.apply(active: palette.primary, inactive: palette.track)
        for button in [closeButton, backButton, playButton, forwardButton, speedButton, followButton] {
            button.apply(foreground: palette.primary, hover: palette.hover)
        }
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        content.frame = effect.bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)

        // Two columns: a flexible one, then a 32pt rail for close and follow-text.
        let left: CGFloat = 18
        let railX = bounds.width - 14 - 32
        let right = railX - 12
        let row1: CGFloat = 14
        let sliderY: CGFloat = row1 + 20 + 4
        let row2: CGFloat = sliderY + 18 + 8

        let timeWidth = ceil(timeLabel.intrinsicContentSize.width)
        timeLabel.frame = NSRect(x: right - timeWidth, y: row1 + 2, width: timeWidth, height: 16)
        titleLabel.frame = NSRect(x: left - 2, y: row1 + 1, width: max(0, right - timeWidth - 8 - left + 2), height: 18)
        scrubber.frame = NSRect(x: left, y: sliderY, width: right - left, height: 18)
        closeButton.frame = NSRect(x: railX + 2, y: row1 - 4, width: 28, height: 28)

        let spacing: CGFloat = bounds.width < 340 ? 8 : 14
        // The first glyph lines up with the title and track.
        var x = left - 6
        backButton.frame = NSRect(x: x, y: row2, width: 28, height: 28)
        x += 28 + spacing
        playButton.frame = NSRect(x: x, y: row2 - 2, width: 32, height: 32)
        x += 32 + spacing
        forwardButton.frame = NSRect(x: x, y: row2, width: 28, height: 28)

        let speedWidth = max(36, speedButton.titleWidth + 12)
        // The label, not the hover pill, ends under the timestamp.
        speedButton.frame = NSRect(x: right - speedWidth + (speedWidth - speedButton.titleWidth) / 2, y: row2 + 1, width: speedWidth, height: 26)
        followButton.frame = NSRect(x: railX + 2, y: row2, width: 28, height: 28)
    }

    // MARK: - Actions

    @objc private func closeClicked() { onClose?() }
    @objc private func backClicked() { onSkip?(-15) }
    @objc private func playClicked() { onPlayPause?() }
    @objc private func forwardClicked() { onSkip?(15) }
    @objc private func followClicked() { onSetFollow?(!state.autoScrollEnabled) }

    @objc private func speedClicked() {
        let menu = makeSpeedMenu()
        menu.appearance = appearance
        // The location is the menu's top-left corner; keep the whole menu above the button.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: speedButton.bounds.maxY + 6 + menu.size.height), in: speedButton)
    }

    private func makeSpeedMenu() -> NSMenu {
        let menu = NSMenu(title: "Playback Speed")
        for preset in TTSSpeedPreset.allCases {
            let item = NSMenuItem(title: preset.label, action: #selector(speedChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = abs(preset.rawValue - state.rate) < 0.001 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let selectedVoiceID = KokoroVoiceCatalog.resolve(state.voiceIdentifier).id
        let voices = NSMenu(title: "Kokoro Voice")
        for (index, group) in TTSVoiceCatalog.groups(including: selectedVoiceID).enumerated() {
            if index > 0 { voices.addItem(.separator()) }
            voices.addItem(.sectionHeader(title: group.title))
            for voice in group.voices {
                voices.addItem(voiceItem(voice.label, identifier: voice.identifier, selectedID: selectedVoiceID))
            }
        }
        let voice = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voice.submenu = voices
        menu.addItem(voice)
        return menu
    }

    private func voiceItem(_ title: String, identifier: String, selectedID: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(voiceChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = identifier
        item.state = identifier == selectedID ? .on : .off
        return item
    }

    @objc private func speedChosen(_ sender: NSMenuItem) {
        if let rate = sender.representedObject as? Double { onSelectSpeed?(rate) }
    }

    @objc private func voiceChosen(_ sender: NSMenuItem) {
        onSelectVoice?(sender.representedObject as? String)
    }
}

/// Owns the pill's placement at the bottom of the reading pane and its transitions.
final class TTSPlayerHost {
    let view = TTSPlayerView(frame: .zero)
    private weak var pane: NSView?
    private var width: NSLayoutConstraint?
    private var bottom: NSLayoutConstraint?
    private var observer: NSObjectProtocol?
    private(set) var isVisible = false

    init(pane: NSView) {
        self.pane = pane
        view.translatesAutoresizingMaskIntoConstraints = false
        pane.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: pane, queue: .main) { [weak self] _ in
            self?.updateWidth()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            view.alphaValue = 0
            attach(offset: -10)
            pane?.layoutSubtreeIfNeeded()
            animate(duration: 0.18, timing: .easeOut, alpha: 1, offset: -20)
        } else {
            animate(duration: 0.14, timing: .easeIn, alpha: 0, offset: -12) { [weak self] in
                guard let self, !self.isVisible else { return }
                self.view.removeFromSuperview()
            }
        }
    }

    /// Panes add views later (contact sheet), which would otherwise cover the pill.
    func bringToFront() {
        guard isVisible, let pane, pane.subviews.last !== view else { return }
        attach(offset: -20)
    }

    private func attach(offset: CGFloat) {
        guard let pane else { return }
        view.removeFromSuperview()
        pane.addSubview(view)
        let width = view.widthAnchor.constraint(equalToConstant: TTSPlayerView.width(forPane: pane.bounds.width))
        let bottom = view.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: offset)
        NSLayoutConstraint.activate([
            width,
            bottom,
            view.heightAnchor.constraint(equalToConstant: TTSPlayerView.height),
            view.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
        ])
        self.width = width
        self.bottom = bottom
    }

    private func updateWidth() {
        guard let pane else { return }
        width?.constant = TTSPlayerView.width(forPane: pane.bounds.width)
    }

    private func animate(duration: TimeInterval, timing: CAMediaTimingFunctionName, alpha: CGFloat, offset: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            view.animator().alphaValue = alpha
            bottom?.animator().constant = offset
        } completionHandler: {
            completion?()
        }
    }
}

/// Flipped for top-down layout; keeps clicks on the pill away from the document.
private final class TTSPillContentView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

private final class TTSPillButton: NSControl {
    var symbol: String? { didSet { needsDisplay = true } }
    var title = "" {
        didSet {
            setAccessibilityValue(title)
            needsDisplay = true
        }
    }
    var isOn = false { didSet { needsDisplay = true } }
    var contentAlpha: CGFloat = 1 { didSet { needsDisplay = true } }
    private let pointSize: CGFloat
    private let weight: NSFont.Weight
    private let radius: CGFloat
    private var foreground = NSColor.labelColor
    private var hoverFill = NSColor.quaternaryLabelColor
    private var hovered = false
    private var pressed = false

    init(symbol: String?, pointSize: CGFloat, weight: NSFont.Weight, radius: CGFloat) {
        self.symbol = symbol
        self.pointSize = pointSize
        self.weight = weight
        self.radius = radius
        super.init(frame: .zero)
        focusRingType = .exterior
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: weight), .foregroundColor: foreground.withAlphaComponent(contentAlpha)]
    }

    var titleWidth: CGFloat { ceil((title as NSString).size(withAttributes: titleAttributes).width) }

    func describe(_ text: String) {
        toolTip = text
        setAccessibilityLabel(text)
    }

    func apply(foreground: NSColor, hover: NSColor) {
        self.foreground = foreground
        hoverFill = hover
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || pressed || isOn {
            (isOn && !hovered ? foreground.withAlphaComponent(0.10) : hoverFill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let alpha = contentAlpha * (pressed ? 0.6 : 1)
        if let symbol {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [foreground]))
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?.withSymbolConfiguration(configuration) else { return }
            let size = image.size
            let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        } else {
            let size = (title as NSString).size(withAttributes: titleAttributes)
            (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: titleAttributes)
        }
    }
}

/// A slim seek track: click anywhere or drag; the seek commits on mouse up.
private final class TTSScrubberControl: NSControl {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var duration: TimeInterval = 0
    private(set) var isDragging = false
    var onScrub: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    private var activeColor = NSColor.labelColor
    private var inactiveColor = NSColor.quaternaryLabelColor

    func apply(active: NSColor, inactive: NSColor) {
        activeColor = active
        inactiveColor = inactive
        needsDisplay = true
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Position in chapter" }
    override func accessibilityValue() -> Any? { TTSTimeEstimator.formatElapsed(fraction * duration) }
    override func accessibilityPerformIncrement() -> Bool { nudge(0.05) }
    override func accessibilityPerformDecrement() -> Bool { nudge(-0.05) }

    private func nudge(_ delta: Double) -> Bool {
        onCommit?(min(max(fraction + delta, 0), 1))
        return true
    }

    private let largestThumb: CGFloat = 13

    private func track(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let span = max(bounds.width - largestThumb, 1)
        fraction = Double(min(max((x - largestThumb / 2) / span, 0), 1))
        onScrub?(fraction)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        track(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging { track(event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        track(event)
        isDragging = false
        needsDisplay = true
        onCommit?(fraction)
    }

    override func draw(_ dirtyRect: NSRect) {
        let thumb: CGFloat = isDragging ? largestThumb : 11
        let line = NSRect(x: 0, y: bounds.midY - 1.25, width: bounds.width, height: 2.5)
        // The thumb stays inside the control at both ends.
        let center = largestThumb / 2 + CGFloat(fraction) * (bounds.width - largestThumb)
        inactiveColor.setFill()
        NSBezierPath(roundedRect: line, xRadius: 1.25, yRadius: 1.25).fill()
        activeColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: line.minY, width: center, height: line.height), xRadius: 1.25, yRadius: 1.25).fill()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 1.5
        shadow.set()
        NSBezierPath(ovalIn: NSRect(x: center - thumb / 2, y: bounds.midY - thumb / 2, width: thumb, height: thumb)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
