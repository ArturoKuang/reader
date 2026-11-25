import AppKit
import ReaderCore

/// The note editor. It is a transient popover: typing saves itself, and an empty body drops the note.
final class NotePopoverController: NSObject, NSTextViewDelegate, NSPopoverDelegate {
    private let popover = NSPopover()
    private let textView = PlaceholderTextView()
    private let saved = NSTextField(labelWithString: "Saved")
    private let location = NSTextField(labelWithString: "")
    private let completion = NSStackView()
    private let colors = NSStackView()
    private var swatches: [SwatchControl] = []
    private var savedTimer: Timer?
    private weak var session: ReaderSession?
    private var annotationID: String?
    private var token: NoteEditToken?
    private var choices: [Concept] = []
    private var choiceIndex = 0
    private var suppressChange = false

    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: 196)
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = build()
    }

    func show(id: String, token: NoteEditToken, session: ReaderSession, relativeTo rect: NSRect, of view: NSView) {
        // Finish the note that is open before this one claims the popover.
        closeIfShown()
        self.session = session
        annotationID = id
        self.token = token
        let item = session.annotation(matching: id)
        suppressChange = true
        textView.string = item?.body ?? ""
        textView.placeholder = "Write a note…"
        location.stringValue = item?.page.map { "p. \($0)" } ?? item?.section ?? ""
        // A standalone note has no highlight, so there is no color to pick.
        colors.isHidden = item?.highlight == nil
        updateSwatches(selected: item?.color ?? session.package.state.lastHighlightColor)
        suppressChange = false
        savedTimer?.invalidate()
        saved.isHidden = true
        hideCompletion()
        popover.appearance = view.window?.effectiveAppearance
        popover.show(relativeTo: anchor(for: rect, in: view), of: view, preferredEdge: edge(for: rect, in: view))
        DispatchQueue.main.async { [weak self] in
            self?.textView.window?.makeFirstResponder(self?.textView)
        }
    }

    /// The part of the highlight that is on screen, so a partly scrolled-off passage still anchors.
    private func anchor(for rect: NSRect, in view: NSView) -> NSRect {
        let visible = view.visibleRect.insetBy(dx: 4, dy: 4)
        guard rect.intersects(visible) else { return rect }
        let clipped = rect.intersection(visible)
        return clipped.width > 0 && clipped.height > 0 ? clipped : rect
    }

    /// Opens on the side with room, so the popover never covers the highlighted text.
    private func edge(for rect: NSRect, in view: NSView) -> NSRectEdge {
        let visible = view.visibleRect.insetBy(dx: 4, dy: 4)
        let anchor = anchor(for: rect, in: view)
        let needed = popover.contentSize.height + 18
        if view.isFlipped {
            let below = visible.maxY - anchor.maxY
            let above = anchor.minY - visible.minY
            return (below >= needed || below >= above) ? .maxY : .minY
        }
        let below = anchor.minY - visible.minY
        let above = visible.maxY - anchor.maxY
        return (below >= needed || below >= above) ? .minY : .maxY
    }

    private func updateSwatches(selected color: Int) {
        for swatch in swatches { swatch.checked = swatch.tag == color }
    }

    func popoverDidClose(_ notification: Notification) {
        // A late notification from a popover that has since been shown again is not this edit's end.
        guard !popover.isShown else { return }
        finishEdit()
    }

    /// Saves the open note and closes before returning.
    func closeIfShown() {
        finishEdit()
        closeNow()
    }

    /// Closes without saving when this editor's note was removed or replaced.
    func dismiss(ifEditing tokens: [NoteEditToken]) {
        guard let token, tokens.contains(token) else { return }
        self.token = nil
        annotationID = nil
        closeNow()
    }

    private func finishEdit() {
        savedTimer?.invalidate()
        guard let token else { return }
        self.token = nil
        annotationID = nil
        session?.endNoteEdit(token)
    }

    private func closeNow() {
        guard popover.isShown else { return }
        popover.animates = false
        popover.close()
        popover.animates = true
    }

    private func build() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 196))
        colors.orientation = .horizontal
        colors.spacing = 4
        colors.translatesAutoresizingMaskIntoConstraints = false
        colors.setContentCompressionResistancePriority(.required, for: .horizontal)
        colors.setContentHuggingPriority(.required, for: .horizontal)
        for index in 1...6 {
            let swatch = SwatchControl(side: 22, dot: 15)
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.tag = index
            if let rgb = HighlightPalette.rgb(index) {
                swatch.fill = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
            }
            let name = HighlightCallout.name(for: index).capitalized
            swatch.toolTip = name
            swatch.setAccessibilityLabel(name)
            swatch.target = self
            swatch.action = #selector(recolor(_:))
            swatches.append(swatch)
            colors.addArrangedSubview(swatch)
        }
        location.font = .systemFont(ofSize: 11, weight: .regular)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingTail
        location.maximumNumberOfLines = 1
        location.alignment = .right
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        location.setContentHuggingPriority(.defaultLow, for: .horizontal)
        location.translatesAutoresizingMaskIntoConstraints = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 304, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 304, height: 72)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        completion.orientation = .vertical
        completion.alignment = .leading
        completion.translatesAutoresizingMaskIntoConstraints = false
        completion.isHidden = true
        saved.font = .systemFont(ofSize: 11)
        saved.textColor = .secondaryLabelColor
        saved.translatesAutoresizingMaskIntoConstraints = false
        saved.isHidden = true
        let more = NSButton()
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Note actions")
        more.bezelStyle = .inline
        more.isBordered = false
        more.contentTintColor = .secondaryLabelColor
        more.toolTip = "Note Actions"
        more.target = self
        more.action = #selector(showMenu(_:))
        more.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(colors)
        root.addSubview(location)
        root.addSubview(scroll)
        root.addSubview(completion)
        root.addSubview(saved)
        root.addSubview(more)
        NSLayoutConstraint.activate([
            colors.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            colors.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            location.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            location.leadingAnchor.constraint(greaterThanOrEqualTo: colors.trailingAnchor, constant: 12),
            location.centerYAnchor.constraint(equalTo: colors.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: colors.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: saved.topAnchor, constant: -4),
            completion.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            completion.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            completion.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            saved.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            saved.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            more.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            more.centerYAnchor.constraint(equalTo: saved.centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: 22),
            more.heightAnchor.constraint(equalToConstant: 22),
        ])
        return root
    }

    func textDidChange(_ notification: Notification) {
        guard !suppressChange, let token else { return }
        session?.queueNoteBody(token, body: textView.string)
        markSaving()
        updateCompletion()
        textView.needsDisplay = true
    }

    /// "Saving…" while typing is pending, then "Saved" once the session has flushed it.
    private func markSaving() {
        saved.stringValue = "Saving…"
        saved.isHidden = false
        savedTimer?.invalidate()
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.saved.stringValue = "Saved"
        }
        RunLoop.main.add(timer, forMode: .common)
        savedTimer = timer
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if !completion.isHidden {
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                choiceIndex = min(choiceIndex + 1, max(choices.count - 1, 0))
                updateCompletion()
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                choiceIndex = max(choiceIndex - 1, 0)
                updateCompletion()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertTab(_:)) {
                insertChoice()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                hideCompletion()
                return true
            }
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            popover.performClose(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            popover.performClose(nil)
            return true
        }
        return false
    }

    @objc private func recolor(_ sender: SwatchControl) {
        guard let id = annotationID, let session, session.annotation(matching: id)?.highlight != nil else { return }
        // Recoloring changes only the highlight, so the open note keeps its typing.
        session.recolorAnnotation(id: id, color: sender.tag)
        updateSwatches(selected: sender.tag)
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(item("Copy Link", #selector(copyLink)))
        if session?.usesVault == true {
            menu.addItem(item("Reveal in Obsidian", #selector(reveal)))
        }
        let annotation = session.flatMap { annotationID.flatMap($0.annotation(matching:)) }
        if annotation?.highlight == nil {
            // A standalone note: removing it is the only removal.
            if annotation?.hasNote == true { menu.addItem(item("Remove Note", #selector(removeBoth))) }
        } else {
            if annotation?.hasNote == true {
                menu.addItem(item("Remove Note", #selector(removeNote)))
                menu.addItem(item("Remove Highlight & Note", #selector(removeBoth)))
            } else {
                menu.addItem(item("Remove Highlight", #selector(removeBoth)))
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func copyLink() {
        guard let session, let id = annotationID, let item = session.annotation(matching: id) else { return }
        let link = ReaderLink(path: session.bookURL.path, location: item.cfi ?? item.page.map { "page=\($0)" }, id: item.id)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
    }

    @objc private func reveal() { session?.onRevealInObsidian?(annotationID) }
    @objc private func removeNote() {
        if let id = annotationID { session?.removeNoteOnly(id: id) }
        closeIfShown()
    }
    @objc private func removeBoth() {
        if let id = annotationID { session?.removeAnnotationCompletely(id: id) }
        closeIfShown()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateCompletion() {
        guard session?.usesVault == true, let session else { hideCompletion(); return }
        let cursor = textView.selectedRange().location
        let prefix = (textView.string as NSString).substring(to: min(cursor, (textView.string as NSString).length))
        guard let range = prefix.range(of: "[[", options: .backwards) else { hideCompletion(); return }
        let query = String(prefix[range.upperBound...])
        if query.contains("]]") { hideCompletion(); return }
        choices = Array(ConceptsFile.autocomplete(prefix: query, concepts: session.concepts).prefix(6))
        choiceIndex = min(choiceIndex, max(choices.count - 1, 0))
        completion.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !choices.isEmpty else { hideCompletion(); return }
        for (index, concept) in choices.enumerated() {
            let button = NSButton(title: concept.wiki, target: self, action: #selector(chooseConcept(_:)))
            button.tag = index
            button.bezelStyle = .inline
            button.alignment = .left
            if index == choiceIndex { button.contentTintColor = .controlAccentColor }
            completion.addArrangedSubview(button)
        }
        completion.isHidden = false
    }

    @objc private func chooseConcept(_ sender: NSButton) {
        choiceIndex = sender.tag
        insertChoice()
    }

    private func insertChoice() {
        guard choices.indices.contains(choiceIndex) else { return }
        let concept = choices[choiceIndex]
        session?.onInsertConcept?(concept)
        let cursor = textView.selectedRange().location
        let whole = textView.string as NSString
        let prefix = whole.substring(to: min(cursor, whole.length))
        guard let range = prefix.range(of: "[[", options: .backwards) else { return }
        let start = prefix.distance(from: prefix.startIndex, to: range.lowerBound)
        textView.insertText(concept.wiki, replacementRange: NSRange(location: start, length: cursor - start))
        hideCompletion()
    }

    private func hideCompletion() {
        completion.isHidden = true
        choices = []
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: 13),
        ]
        // The view is flipped, so the text container origin is the top-left caret position.
        let padding = textContainer?.lineFragmentPadding ?? 5
        placeholder.draw(at: NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y), withAttributes: attributes)
    }
}
