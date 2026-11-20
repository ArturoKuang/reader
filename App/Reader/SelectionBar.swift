import AppKit
import QuartzCore
import ReaderCore

/// A small material bar above a finished text selection. It is not an NSPopover:
/// the system popover sat on the line above the selection and drew a heavy capsule.
final class SelectionBarController: NSObject {
    private weak var session: ReaderSession?
    private var bar: SelectionChrome?
    private var monitor: Any?
    private var dismissing = false

    func dismiss() {
        guard let bar, !dismissing else { return }
        dismissing = true
        removeMonitor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            bar.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            bar.removeFromSuperview()
            if self?.bar === bar { self?.bar = nil }
            self?.dismissing = false
        }
    }

    func show(session: ReaderSession, relativeTo selection: NSRect, of host: NSView) {
        guard session.settings.showSelectionBar, selection.width > 1, selection.height > 1 else { return }
        self.session = session
        if let bar {
            bar.removeFromSuperview()
            self.bar = nil
        }
        dismissing = false
        let current = currentColor(in: session)
        let visible = host.convert(host.visibleRect, to: nil)
        var chrome = SelectionChrome(compact: false, currentColor: current, target: self)
        if chrome.fittingWidth > visible.width - 16 {
            chrome = SelectionChrome(compact: true, currentColor: current, target: self)
        }
        let placed = place(chromeSize: chrome.preferredSize, selection: selection, host: host)
        chrome.pointingDown = placed.pointingDown
        chrome.arrowX = placed.arrowX
        guard let content = host.window?.contentView else { return }
        chrome.frame = content.convert(placed.windowFrame, from: nil)
        chrome.alphaValue = 0
        chrome.wantsLayer = true
        chrome.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        content.addSubview(chrome)
        self.bar = chrome
        installMonitor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            chrome.animator().alphaValue = 1
        }
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DMakeScale(0.96, 0.96, 1)
        scale.toValue = CATransform3DIdentity
        scale.duration = 0.12
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        chrome.layer?.add(scale, forKey: "appear")
        chrome.layer?.transform = CATransform3DIdentity
    }

    private func place(chromeSize: NSSize, selection: NSRect, host: NSView) -> (windowFrame: NSRect, arrowX: CGFloat, pointingDown: Bool) {
        let gap: CGFloat = 8
        let selected = host.convert(selection, to: nil)
        let visible = host.convert(host.visibleRect, to: nil)
        var pointingDown = true
        var originY = selected.maxY + gap
        if visible.maxY - originY < chromeSize.height {
            pointingDown = false
            originY = selected.minY - gap - chromeSize.height
        }
        originY = min(max(originY, visible.minY + 4), max(visible.minY + 4, visible.maxY - chromeSize.height - 4))
        var originX = selected.midX - chromeSize.width / 2
        originX = min(max(originX, visible.minX + 8), max(visible.minX + 8, visible.maxX - chromeSize.width - 8))
        let windowFrame = NSRect(x: originX, y: originY, width: chromeSize.width, height: chromeSize.height)
        let arrowX = min(max(selected.midX - originX, 16), chromeSize.width - 16)
        return (windowFrame, arrowX, pointingDown)
    }

    private func currentColor(in session: ReaderSession) -> Int? {
        guard let selection = session.selection else { return nil }
        return AnnotationIndex.highlight(matchingQuote: selection.text, page: selection.page, cfi: selection.cfi, in: session.highlights)?.color
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let bar = self.bar, bar.window != nil else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
                return event
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let point = bar.convert(event.locationInWindow, from: nil)
                if !bar.bounds.contains(point) { self.dismiss() }
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        self.monitor = nil
    }

    @objc func colorClicked(_ sender: NSControl) {
        let color = sender.tag
        guard let session, let selection = session.selection else { dismiss(); return }
        let existing = AnnotationIndex.highlight(matchingQuote: selection.text, page: selection.page, cfi: selection.cfi, in: session.highlights)
        if color == 0 {
            if let id = existing?.id { session.deleteHighlight(id: id) }
        } else if let id = existing?.id {
            session.recolorAnnotation(id: id, color: color)
        } else {
            session.highlight(color: color)
        }
        dismiss()
    }

    @objc func noteClicked(_ sender: Any?) { session?.addNote(); dismiss() }
    @objc func lookUpClicked(_ sender: Any?) { session?.lookUp(); dismiss() }
    @objc func askClicked(_ sender: Any?) { session?.show(tab: .askAI); dismiss() }
    @objc func copyClicked(_ sender: Any?) {
        guard let text = session?.selection?.text else { dismiss(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        dismiss()
    }
}

private final class SelectionChrome: NSView {
    var pointingDown = true
    var arrowX: CGFloat = 0
    private let effect = NSVisualEffectView()
    private let border = CAShapeLayer()
    private let controls: NSView
    let preferredSize: NSSize
    var fittingWidth: CGFloat { preferredSize.width }
    private let arrowHeight: CGFloat = 7

    init(compact: Bool, currentColor: Int?, target: SelectionBarController) {
        let row = SelectionChrome.makeRow(compact: compact, currentColor: currentColor, target: target)
        controls = row
        let content = row.fittingSize
        preferredSize = NSSize(width: content.width + 16, height: content.height + 8 + arrowHeight)
        super.init(frame: NSRect(origin: .zero, size: preferredSize))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        border.fillColor = nil
        border.lineWidth = 0.5
        layer?.addSublayer(border)
        addSubview(effect)
        effect.addSubview(controls)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let body: NSRect
        if pointingDown {
            body = NSRect(x: 0, y: arrowHeight, width: bounds.width, height: bounds.height - arrowHeight)
        } else {
            body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - arrowHeight)
        }
        effect.frame = bounds
        controls.frame = body.insetBy(dx: 8, dy: 4)
        let path = bubblePath(body: body)
        let mask = CAShapeLayer()
        mask.path = path
        effect.layer?.mask = mask
        border.frame = bounds
        border.path = path
        effectiveAppearance.performAsCurrentDrawingAppearance {
            border.strokeColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func bubblePath(body: NSRect) -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: 10, cornerHeight: 10)
        let width = bounds.width
        let base = min(max(arrowX, 18), width - 18)
        if pointingDown {
            path.move(to: CGPoint(x: base - 6, y: body.minY))
            path.addLine(to: CGPoint(x: base, y: 0))
            path.addLine(to: CGPoint(x: base + 6, y: body.minY))
        } else {
            path.move(to: CGPoint(x: base - 6, y: body.maxY))
            path.addLine(to: CGPoint(x: base, y: bounds.maxY))
            path.addLine(to: CGPoint(x: base + 6, y: body.maxY))
        }
        path.closeSubpath()
        return path
    }

    private static func makeRow(compact: Bool, currentColor: Int?, target: SelectionBarController) -> NSView {
        var views: [NSView] = []
        for color in 1...6 {
            let swatch = SwatchControl(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
            swatch.tag = color
            swatch.checked = currentColor == color
            if let rgb = HighlightPalette.rgb(color) {
                swatch.fill = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
            }
            let name = "Highlight \(HighlightCallout.name(for: color).capitalized)"
            swatch.toolTip = name
            swatch.target = target
            swatch.action = #selector(SelectionBarController.colorClicked(_:))
            views.append(swatch)
        }
        if currentColor != nil {
            let remove = SwatchControl(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
            remove.tag = 0
            remove.removeStyle = true
            remove.toolTip = "Remove Highlight"
            remove.target = target
            remove.action = #selector(SelectionBarController.colorClicked(_:))
            views.append(remove)
        }
        views.append(DividerLine(frame: NSRect(x: 0, y: 0, width: 9, height: 24)))
        let actions: [(String, String, String, Selector)] = [
            ("note.text", "Note", "⇧⌘N", #selector(SelectionBarController.noteClicked(_:))),
            ("character.book.closed", "Look Up", "⌃⌘D", #selector(SelectionBarController.lookUpClicked(_:))),
            ("sparkles", "Ask AI", "⌘K", #selector(SelectionBarController.askClicked(_:))),
            ("doc.on.doc", "Copy", "⌘C", #selector(SelectionBarController.copyClicked(_:))),
        ]
        for action in actions {
            let button = BarButton(symbol: action.0, title: action.1, showsTitle: !compact)
            button.toolTip = compact ? "\(action.1) (\(action.2))" : action.2
            button.target = target
            button.action = action.3
            views.append(button)
        }
        return Row(views: views)
    }
}

private final class Row: NSView {
    init(views: [NSView]) {
        super.init(frame: .zero)
        var x: CGFloat = 0
        let height = views.map(\.fittingSize.height).max() ?? 26
        for view in views {
            let size = view.fittingSize
            view.frame = NSRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            addSubview(view)
            x += size.width
        }
        frame = NSRect(x: 0, y: 0, width: x, height: height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var fittingSize: NSSize { frame.size }
}

private final class DividerLine: NSView {
    override var fittingSize: NSSize { NSSize(width: 9, height: 24) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 4, y: 4, width: 1, height: bounds.height - 8).fill()
    }
}

private final class SwatchControl: NSControl {
    var fill: NSColor = .systemYellow
    var checked = false
    var removeStyle = false
    private var hovered = false

    override var fittingSize: NSSize { NSSize(width: 24, height: 24) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { toolTip }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill() }

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

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale: CGFloat = hovered ? 1.15 : 1
        let side = 16 * scale
        let rect = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        if removeStyle {
            NSColor.secondaryLabelColor.setStroke()
            circle.lineWidth = 1.25
            circle.stroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 3))
            slash.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 3))
            slash.lineWidth = 1.25
            slash.lineCapStyle = .round
            slash.stroke()
        } else {
            fill.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            if checked {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: rect.midX - 3.2, y: rect.midY - 0.2))
                check.line(to: NSPoint(x: rect.midX - 0.8, y: rect.midY - 2.6))
                check.line(to: NSPoint(x: rect.midX + 3.6, y: rect.midY + 2.8))
                NSColor.black.withAlphaComponent(0.8).setStroke()
                check.lineWidth = 1.4
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            }
        }
        if hovered || checked {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
            (hovered ? NSColor.controlAccentColor : NSColor.labelColor).setStroke()
            ring.lineWidth = hovered ? 1.5 : 1
            ring.stroke()
        }
    }
}

private final class BarButton: NSControl {
    private let symbol: String
    private let titleText: String
    private let showsTitle: Bool
    private var hovered = false

    init(symbol: String, title: String, showsTitle: Bool) {
        self.symbol = symbol
        self.titleText = title
        self.showsTitle = showsTitle
        super.init(frame: .zero)
        let size = Self.measuredSize(title: title, showsTitle: showsTitle)
        frame = NSRect(origin: .zero, size: size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var fittingSize: NSSize { frame.size }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { toolTip ?? titleText }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    private static func measuredSize(title: String, showsTitle: Bool) -> NSSize {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        if !showsTitle { return NSSize(width: 34, height: 26) }
        let text = (title as NSString).size(withAttributes: [.font: font])
        return NSSize(width: 10 + 14 + 4 + ceil(text.width) + 10, height: 26)
    }

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

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: titleText)?.withSymbolConfiguration(config)
        let icon = NSRect(x: showsTitle ? 10 : (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
        image?.draw(in: icon)
        guard showsTitle else { return }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let textSize = (titleText as NSString).size(withAttributes: attributes)
        let textRect = NSRect(x: 28, y: (bounds.height - textSize.height) / 2, width: textSize.width, height: textSize.height)
        (titleText as NSString).draw(in: textRect, withAttributes: attributes)
    }
}
