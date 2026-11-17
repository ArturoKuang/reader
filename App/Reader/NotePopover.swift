import AppKit
import ReaderCore

/// The note editor. It is a transient popover: typing saves itself, and an empty body drops the note.
final class NotePopoverController: NSObject, NSTextViewDelegate, NSPopoverDelegate {
    private let popover = NSPopover()
    private let textView = PlaceholderTextView()
    private let saved = NSTextField(labelWithString: "Saved")
    private let location = NSTextField(labelWithString: "")
    private let completion = NSStackView()
    private var colorButtons: [NSButton] = []
    private weak var session: ReaderSession?
    private var annotationID: String?
    private var choices: [Concept] = []
    private var choiceIndex = 0
    private var suppressChange = false

    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: 180)
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = build()
    }

    func show(id: String, session: ReaderSession, relativeTo rect: NSRect, of view: NSView) {
        self.session = session
        annotationID = id
        let item = session.annotations.first { $0.id == id || $0.note?.id == id || $0.highlight?.id == id }
        suppressChange = true
        textView.string = item?.body ?? ""
        textView.placeholder = (item?.hasNote == true) ? "Write a note…" : "Add Note"
        location.stringValue = item?.page.map { "p. \($0)" } ?? item?.section ?? ""
        let color = item?.color ?? session.package.state.lastHighlightColor
        for button in colorButtons {
            button.state = button.tag == color ? .on : .off
        }
        suppressChange = false
        saved.isHidden = true
        hideCompletion()
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        DispatchQueue.main.async { [weak self] in
            self?.textView.window?.makeFirstResponder(self?.textView)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        session?.flushNoteBodies()
    }

    private func build() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let colors = NSStackView()
        colors.orientation = .horizontal
        colors.spacing = 6
        colors.translatesAutoresizingMaskIntoConstraints = false
        for index in 1...6 {
            let button = NSButton()
            button.setButtonType(.radio)
            button.title = ""
            button.bezelStyle = .circular
            button.tag = index
            button.target = self
            button.action = #selector(recolor(_:))
            if let rgb = HighlightPalette.rgb(index) {
                button.contentTintColor = NSColor(calibratedRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
            }
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Color \(index)")
            colorButtons.append(button)
            colors.addArrangedSubview(button)
        }
        location.font = .systemFont(ofSize: 11)
        location.textColor = .secondaryLabelColor
        location.translatesAutoresizingMaskIntoConstraints = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.delegate = self
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
        ])
        return root
    }

    func textDidChange(_ notification: Notification) {
        guard !suppressChange, let id = annotationID else { return }
        session?.queueNoteBody(id: id, body: textView.string)
        saved.isHidden = false
        updateCompletion()
        textView.needsDisplay = true
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

    @objc private func recolor(_ sender: NSButton) {
        guard let id = annotationID else { return }
        session?.recolorAnnotation(id: id, color: sender.tag)
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(item("Copy Link", #selector(copyLink)))
        if session?.usesVault == true {
            menu.addItem(item("Reveal in Obsidian", #selector(reveal)))
        }
        menu.addItem(item("Remove Note", #selector(removeNote)))
        menu.addItem(item("Remove Highlight & Note", #selector(removeBoth)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func copyLink() {
        guard let session, let id = annotationID, let item = session.annotations.first(where: { $0.id == id || $0.highlight?.id == id }) else { return }
        let link = ReaderLink(path: session.bookURL.path, location: item.cfi ?? item.page.map { "page=\($0)" }, id: item.id)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
    }

    @objc private func reveal() { session?.onRevealInObsidian?() }
    @objc private func removeNote() {
        if let id = annotationID { session?.removeNoteOnly(id: id) }
        popover.performClose(nil)
    }
    @objc private func removeBoth() {
        if let id = annotationID { session?.removeAnnotationCompletely(id: id) }
        popover.performClose(nil)
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
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 4, y: bounds.height - 20), withAttributes: attributes)
    }
}
