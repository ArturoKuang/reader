import AppKit
import PDFKit
import ReaderCore
import SwiftUI

/// The document view is a PDFView, not a SwiftUI scroll view. Pinch zoom, continuous
/// scroll, and page navigation are PDFKit's. Reader only draws annotations and note
/// markers on top and lets hits fall through everywhere except those controls.
final class PDFContainerViewController: NSViewController {
    let session: ReaderSession
    private let pdfView = ReaderPDFView()
    private let overlay = NoteOverlay()
    private let findBar = NSSearchField()
    private var findTop: NSLayoutConstraint?
    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    private var contactHost: NSHostingController<ContactSheetView>?
    private var annotations: [PDFAnnotation] = []
    private var highlightIDs: [ObjectIdentifier: String] = [:]
    private var lookupPopover: NSPopover?
    private var didApplyInitialScale = false
    private var suppressScaleSave = false

    init(session: ReaderSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = false
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.displayBox = .mediaBox
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 8
        pdfView.document = session.pdfDocument
        view.addSubview(pdfView)
        overlay.pdfView = pdfView
        overlay.session = session
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.placeholderString = "Find"
        findBar.target = self
        findBar.action = #selector(findFromBar)
        findBar.isHidden = true
        view.addSubview(findBar)
        let findConstraint = findBar.topAnchor.constraint(equalTo: view.topAnchor, constant: -40)
        findTop = findConstraint
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.topAnchor.constraint(equalTo: findBar.bottomAnchor, constant: 4),
            overlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            findBar.widthAnchor.constraint(equalToConstant: 240),
            findConstraint,
        ])
        applyDisplayMode()
        if session.hasSavedViewState && session.fitMode == .fitPage {
            pdfView.autoScales = true
        } else if session.hasSavedViewState && session.fitMode == .actual {
            pdfView.scaleFactor = 1
        } else if session.hasSavedViewState && session.fitMode == .custom {
            pdfView.scaleFactor = min(max(session.zoom, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)
        pdfView.onMouseUp = { [weak self] in self?.captureSelection() }
        pdfView.highlightIDAt = { [weak self] point in self?.highlightID(atViewPoint: point) }
        pdfView.onRemoveHighlight = { [weak self] id in self?.session.deleteHighlight(id: id) }
        session.onAnnotationsChanged = { [weak self] in self?.refreshAnnotations() }
        refreshAnnotations()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didApplyInitialScale else { return }
        guard pdfView.bounds.width > 80, pdfView.currentPage != nil else { return }
        didApplyInitialScale = true
        // A first open has no saved zoom. Fit the page width once the window has a real size.
        // Later opens keep a custom or actual-size zoom and only refit when that was the saved mode.
        if !session.hasSavedViewState || session.fitMode == .fitWidth {
            fitWidth()
        }
        guard session.hasSavedViewState else { return }
        let state = session.package.state
        reveal(ReadingPosition(page: state.page, scrollY: state.scrollY, zoom: nil))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let clip = enclosingScrollClip(in: pdfView) else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    override func viewWillDisappear() {
        session.rememberScroll(currentPosition())
        session.saveViewQuietly()
        super.viewWillDisappear()
    }

    func applyDisplayMode() {
        switch (session.continuous, session.twoPages) {
        case (true, false): pdfView.displayMode = .singlePageContinuous
        case (false, false): pdfView.displayMode = .singlePage
        case (true, true): pdfView.displayMode = .twoUpContinuous
        case (false, true): pdfView.displayMode = .twoUp
        }
    }

    func setContactSheet(_ visible: Bool) {
        contactHost?.view.removeFromSuperview()
        contactHost = nil
        pdfView.isHidden = visible
        overlay.isHidden = visible
        guard visible, let document = session.pdfDocument else { return }
        let host = NSHostingController(rootView: ContactSheetView(document: document, session: session) { [weak self] page in
            self?.session.setSidebar(.thumbnails)
            self?.reveal(ReadingPosition(page: page))
            (self?.view.window?.windowController as? ReaderWindowController)?.applyChrome()
        })
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        contactHost = host
    }

    func actualSize() {
        suppressScaleSave = true
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        suppressScaleSave = false
        session.rememberZoom(1, fit: .actual)
    }

    func zoomToFit() {
        suppressScaleSave = true
        pdfView.autoScales = true
        suppressScaleSave = false
        session.rememberZoom(pdfView.scaleFactor, fit: .fitPage)
    }

    func fitWidth() {
        pdfView.autoScales = false
        guard let page = pdfView.currentPage else { return }
        let width = page.bounds(for: pdfView.displayBox).width
        let available = pdfView.bounds.width - 24
        guard width > 1, available > 80 else { return }
        suppressScaleSave = true
        pdfView.scaleFactor = available / width
        suppressScaleSave = false
        session.rememberZoom(pdfView.scaleFactor, fit: .fitWidth)
    }

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }

    func zoomToSelection() {
        guard let selection = pdfView.currentSelection, let page = selection.pages.first else { return }
        let bounds = selection.bounds(for: page)
        pdfView.autoScales = false
        let size = pdfView.bounds.size
        let factor = min(size.width / max(bounds.width, 1), size.height / max(bounds.height, 1)) * 0.9
        pdfView.scaleFactor = min(max(factor, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        pdfView.go(to: bounds, on: page)
        session.rememberZoom(pdfView.scaleFactor, fit: .custom)
    }

    func nextPage() { pdfView.goToNextPage(nil) }
    func previousPage() { pdfView.goToPreviousPage(nil) }

    func goBack() -> Bool {
        guard pdfView.canGoBack else { return false }
        pdfView.goBack(nil)
        return true
    }

    func goForward() -> Bool {
        guard pdfView.canGoForward else { return false }
        pdfView.goForward(nil)
        return true
    }

    func toggleFind() {
        findBar.isHidden.toggle()
        findTop?.constant = findBar.isHidden ? -40 : 8
        if !findBar.isHidden { view.window?.makeFirstResponder(findBar) }
    }

    @objc private func findFromBar() { runFind(forward: true) }
    func findNext() { runFind(forward: true) }
    func findPrevious() { runFind(forward: false) }

    private func runFind(forward: Bool) {
        let query = findBar.stringValue.isEmpty ? session.findQuery : findBar.stringValue
        session.findQuery = query
        guard !query.isEmpty, let document = pdfView.document else { return }
        if matches.isEmpty || matches.first?.string?.localizedCaseInsensitiveContains(query) != true {
            matches = document.findString(query, withOptions: [.caseInsensitive])
            matchIndex = 0
        } else if forward {
            matchIndex = matches.isEmpty ? 0 : (matchIndex + 1) % matches.count
        } else {
            matchIndex = matches.isEmpty ? 0 : (matchIndex - 1 + matches.count) % matches.count
        }
        guard matches.indices.contains(matchIndex) else { return }
        let selection = matches[matchIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.scrollSelectionToVisible(nil)
    }

    func captureSelection() {
        guard let selection = pdfView.currentSelection, let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let page = selection.pages.first
        let pageNumber = page.flatMap { pdfView.document?.index(for: $0) }.map { $0 + 1 }
        let pageText = page?.string ?? ""
        let span = SentenceSpan.sentence(containing: text, in: pageText)
        var rects: [[Double]] = []
        if let page {
            for line in selection.selectionsByLine() {
                let bounds = line.bounds(for: page)
                rects.append([bounds.minX, bounds.minY, bounds.maxX, bounds.maxY])
            }
        }
        session.selection = SelectionContext(
            text: text,
            page: pageNumber,
            section: session.sectionTitle,
            prefix: span?.prefix ?? "",
            suffix: span?.suffix ?? "",
            sentence: span?.sentence ?? text,
            rects: rects
        )
    }

    func refreshAnnotations() {
        for annotation in annotations {
            annotation.page?.removeAnnotation(annotation)
        }
        annotations.removeAll()
        highlightIDs.removeAll()
        guard let document = pdfView.document else { return }
        for highlight in session.highlights {
            guard let pageNumber = highlight.page, let page = document.page(at: pageNumber - 1) else { continue }
            let rects = highlight.rects.isEmpty ? rectsFor(quote: highlight.quote, on: page) : highlight.rects
            for rect in rects {
                let bounds = NSRect(x: rect[0], y: rect.count > 1 ? rect[1] : 0, width: max((rect.count > 2 ? rect[2] : rect[0]) - rect[0], 4), height: max((rect.count > 3 ? rect[3] : rect[1]) - (rect.count > 1 ? rect[1] : 0), 4))
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = ReaderColor.nsColor(highlight.color).withAlphaComponent(0.35)
                page.addAnnotation(annotation)
                annotations.append(annotation)
                highlightIDs[ObjectIdentifier(annotation)] = highlight.id
            }
        }
        for word in session.words {
            for lookup in word.lookups {
                guard let pageNumber = lookup.page, let page = document.page(at: pageNumber - 1) else { continue }
                for rect in rectsFor(quote: lookup.quote.isEmpty ? word.word : lookup.quote, on: page) {
                    let bounds = NSRect(x: rect[0], y: rect[1], width: max(rect[2] - rect[0], 4), height: max(rect[3] - rect[1], 4))
                    let annotation = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
                    annotation.color = .secondaryLabelColor
                    page.addAnnotation(annotation)
                    annotations.append(annotation)
                }
            }
        }
        overlay.needsLayout = true
    }

    func reveal(_ position: ReadingPosition) {
        guard let document = pdfView.document else { return }
        let index = min(max((position.page ?? 1) - 1, 0), max(document.pageCount - 1, 0))
        guard let page = document.page(at: index) else { return }
        if let zoom = position.zoom {
            pdfView.autoScales = false
            pdfView.scaleFactor = zoom
        }
        let bounds = page.bounds(for: pdfView.displayBox)
        let y = position.pdfY ?? (bounds.maxY - (position.scrollY ?? 0) * bounds.height)
        let rect = NSRect(x: position.pdfX ?? bounds.minX, y: y - 12, width: 12, height: 12)
        pdfView.go(to: rect, on: page)
    }

    func consumePendingJump() {}

    func currentPosition() -> ReadingPosition {
        guard let page = pdfView.currentPage, let document = pdfView.document else {
            return ReadingPosition(page: session.page, zoom: pdfView.scaleFactor)
        }
        let number = document.index(for: page) + 1
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let visible = pdfView.convert(pdfView.bounds, to: page)
        let fromTop = pageBounds.maxY - visible.maxY
        let scroll = pageBounds.height > 0 ? min(max(fromTop / pageBounds.height, 0), 1) : 0
        return ReadingPosition(
            page: number,
            scrollY: scroll,
            zoom: pdfView.scaleFactor,
            pdfX: visible.minX,
            pdfY: visible.maxY,
            section: session.sectionTitle,
            quote: session.selection?.text
        )
    }

    func showLookup() {
        guard session.lookup != nil, let window = view.window else { return }
        let host = NSHostingController(rootView: LookupCard(session: session) { [weak self] in
            self?.lookupPopover?.performClose(nil)
            self?.refreshAnnotations()
        })
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 240)
        let rect = pdfView.currentSelection?.bounds(for: pdfView.currentPage ?? PDFPage()) ?? pdfView.bounds
        let viewRect = pdfView.currentPage.map { pdfView.convert(rect, from: $0) } ?? pdfView.bounds
        popover.show(relativeTo: viewRect, of: pdfView, preferredEdge: .maxY)
        lookupPopover = popover
    }

    @objc private func pageChanged() {
        guard let page = pdfView.currentPage, let document = pdfView.document else { return }
        let number = document.index(for: page) + 1
        let section = session.outline.last { ($0.page ?? 0) <= number }?.title
        session.updatePage(number, count: document.pageCount, section: section)
        session.rememberScroll(currentPosition())
        session.saveViewQuietly()
        overlay.needsLayout = true
    }

    @objc private func scrolled() {
        session.rememberScroll(currentPosition())
    }

    @objc private func scaleChanged() {
        guard !suppressScaleSave else { return }
        session.rememberZoom(pdfView.scaleFactor, fit: pdfView.autoScales ? .fitPage : .custom)
    }

    private func highlightID(atViewPoint point: NSPoint) -> String? {
        guard let page = pdfView.page(for: point, nearest: true) else { return nil }
        let pagePoint = pdfView.convert(point, to: page)
        for annotation in page.annotations where annotation.bounds.contains(pagePoint) {
            if let id = highlightIDs[ObjectIdentifier(annotation)] { return id }
        }
        return nil
    }

    private func enclosingScrollClip(in view: NSView) -> NSClipView? {
        if let scroll = view as? NSScrollView { return scroll.contentView }
        for subview in view.subviews {
            if let found = enclosingScrollClip(in: subview) { return found }
        }
        return nil
    }

    private func rectsFor(quote: String, on page: PDFPage) -> [[Double]] {
        guard !quote.isEmpty, let string = page.string, let range = string.range(of: quote) else { return [] }
        let nsRange = NSRange(range, in: string)
        guard let selection = page.selection(for: nsRange) else { return [] }
        return selection.selectionsByLine().map { line in
            let bounds = line.bounds(for: page)
            return [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]
        }
    }
}

final class ReaderPDFView: PDFView {
    var onMouseUp: (() -> Void)?
    var highlightIDAt: ((NSPoint) -> String?)?
    var onRemoveHighlight: ((String) -> Void)?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = highlightIDAt?(point) {
            let menu = NSMenu()
            let item = NSMenuItem(title: "Remove Highlight", action: #selector(removeHighlightClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }

    @objc private func removeHighlightClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRemoveHighlight?(id)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        superview?.viewWithTag(77)?.needsLayout = true
    }
}

final class NoteOverlay: NSView {
    weak var pdfView: PDFView?
    weak var session: ReaderSession?
    private var markers: [NSButton] = []

    override var tag: Int { 77 }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        guard let pdfView, let session, let document = pdfView.document else { return }
        markers.forEach { $0.removeFromSuperview() }
        markers.removeAll()
        subviews.filter { $0 is NSBox }.forEach { $0.removeFromSuperview() }
        for note in session.notes {
            guard let pageNumber = note.page, let page = document.page(at: pageNumber - 1) else { continue }
            guard let string = page.string, let range = string.range(of: note.quote), let selection = page.selection(for: NSRange(range, in: string)) else { continue }
            let bounds = pdfView.convert(selection.bounds(for: page), from: page)
            let button = NSButton(title: session.expandedNotes.contains(note.id) ? "▾" : "▸", target: self, action: #selector(toggle(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(note.id)
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 11)
            button.frame = NSRect(x: bounds.maxX + 4, y: bounds.maxY - 16, width: 22, height: 18)
            addSubview(button)
            markers.append(button)
            if session.expandedNotes.contains(note.id) {
                let box = NSBox(frame: NSRect(x: bounds.minX, y: bounds.minY - 78, width: min(bounds.width, 420), height: 72))
                box.boxType = .custom
                box.fillColor = .controlBackgroundColor
                box.borderColor = .controlAccentColor
                box.borderWidth = 1
                box.cornerRadius = 6
                let text = NSTextField(frame: box.bounds.insetBy(dx: 8, dy: 8))
                text.stringValue = note.body.isEmpty ? "Write a note…" : note.body
                text.isEditable = true
                text.isBordered = false
                text.drawsBackground = false
                text.font = .systemFont(ofSize: 12)
                text.identifier = NSUserInterfaceItemIdentifier(note.id)
                text.delegate = self
                box.addSubview(text)
                addSubview(box)
            }
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        session?.toggleNote(id)
        needsLayout = true
    }
}

extension NoteOverlay: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        session?.updateNote(id: id, body: field.stringValue)
    }
}
