import AppKit
import PDFKit
import ReaderCore
import SwiftUI

/// The document view is a PDFView, not a SwiftUI scroll view. Pinch zoom, continuous
/// scroll, and page navigation are PDFKit's. Reader only draws annotations and note
/// markers on top and lets hits fall through everywhere except those controls.
final class PDFContainerViewController: NSViewController {
    let session: ReaderSession
    /// Only the active pane writes the shared page, zoom, and find hits.
    var publishesPosition = true
    var ownsFindSession = false
    private var lockedFit: FitMode?
    private var lockedZoom: Double?
    private let pdfView = ReaderPDFView()
    private let overlay = NoteOverlay()
    private let titleStrip = PaneTitleStrip()
    private var findBar: NSSearchField { titleStrip.findField }
    private var stripTop: NSLayoutConstraint?
    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    private var pickInitialMatch = false
    private var lastFindQuery = ""
    private var findCommitted = false
    private var contactHost: NSHostingController<ContactSheetView>?
    private var annotations: [PDFAnnotation] = []
    private var highlightIDs: [ObjectIdentifier: String] = [:]
    private var conceptIDs: [ObjectIdentifier: String] = [:]
    private var lookupPopover: NSPopover?
    private var didRestorePosition = false
    private var didFinishOpeningLayout = false
    private var applyingJump = false
    private var stickJump: PDFJump?
    private var suppressScaleSave = false
    private var lastFitSize: CGSize = .zero

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
        // Each pane owns a document. A shared PDFDocument only redraws annotations in one PDFView.
        pdfView.document = PDFDocument(data: session.bookData) ?? session.pdfDocument
        applyDisplayedRotations()
        view.addSubview(pdfView)
        overlay.pdfView = pdfView
        overlay.session = session
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        findBar.target = self
        findBar.action = #selector(findFromBar)
        (findBar.cell as? NSActionCell)?.sendsActionOnEndEditing = false
        view.addSubview(titleStrip)
        let stripConstraint = titleStrip.topAnchor.constraint(equalTo: view.topAnchor)
        stripTop = stripConstraint
        NSLayoutConstraint.activate([
            titleStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stripConstraint,
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.topAnchor.constraint(equalTo: titleStrip.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
        ])
        let ring = PaneFocusRing()
        ring.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ring)
        NSLayoutConstraint.activate([
            ring.topAnchor.constraint(equalTo: titleStrip.topAnchor),
            ring.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ring.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        applyDisplayMode()
        // Do not scale here. bounds are still zero, and PDFView would stick at minScaleFactor (10%).
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(foundMatch(_:)), name: .PDFDocumentDidFindMatch, object: pdfView.document)
        NotificationCenter.default.addObserver(self, selector: #selector(findFinished(_:)), name: .PDFDocumentDidEndFind, object: pdfView.document)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)
        pdfView.onMouseUp = { [weak self] in self?.captureSelection() }
        pdfView.highlightIDAt = { [weak self] point in self?.highlightID(atViewPoint: point) }
        pdfView.onRemoveHighlight = { [weak self] id in self?.session.deleteHighlight(id: id) }
        pdfView.onOpenHighlight = { [weak self] id in
            self?.session.lastAnnotationHit = id
            self?.session.openAnnotation(id)
        }
        pdfView.conceptAt = { [weak self] point in self?.conceptID(atViewPoint: point) }
        pdfView.onConcept = { [weak self] id in self?.presentConcept(id) }
        pdfView.session = session
        pdfView.prepareSelection = { [weak self] in self?.captureSelection(showBar: false) }
        pdfView.beginFind = { [weak self] in self?.toggleFind() }
        session.watchAnnotations(self) { [weak self] in
            self?.refreshAnnotations()
        }
        refreshAnnotations()
        setPaneActive(publishesPosition)
    }

    deinit {
        session.unwatchAnnotations(self)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        placePDFBelowToolbar()
        applyFittingScale()
    }

    /// The PDF scroll view fills the full-height pane, which runs under the toolbar.
    /// Move the view down so the page starts at the bottom edge of the bar.
    private func placePDFBelowToolbar() {
        guard let window = view.window, let constraint = stripTop else { return }
        let topInWindow = view.convert(view.bounds, to: nil).maxY
        let overlap = topInWindow - window.contentLayoutRect.maxY
        let constant = overlap > 0.5 ? overlap : 0
        if abs(constraint.constant - constant) > 0.5 {
            constraint.constant = constant
        }
        refreshPaneTitle()
        if let scroll = enclosingScrollClip(in: pdfView)?.enclosingScrollView {
            scroll.automaticallyAdjustsContentInsets = false
            if scroll.contentInsets.top != 0 {
                var insets = scroll.contentInsets
                insets.top = 0
                scroll.contentInsets = insets
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Layout during appearance can still be short of the final window size.
        lastFitSize = .zero
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyFittingScale(force: true)
            self.restorePositionOnce()
            if let stickJump = self.stickJump {
                self.showJump(stickJump, flash: false)
            }
            self.stickJump = nil
            self.didFinishOpeningLayout = true
        }
        guard let clip = enclosingScrollClip(in: pdfView) else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    /// Fit modes track the view size, the way Preview's Zoom to Fit does.
    /// Actual size and a custom scale are applied once, after the view has a real size.
    func applyFittingScale(force: Bool = false) {
        guard view.window != nil else { return }
        let bounds = pdfView.bounds
        guard bounds.width > 160, bounds.height > 160, pdfView.document != nil else { return }
        let anchored = pdfView.currentDestination
        let mode: FitMode = {
            if !publishesPosition, let lockedFit { return lockedFit }
            return session.hasSavedViewState ? session.fitMode : .fitPage
        }()
        switch mode {
        case .fitPage:
            guard force || bounds.size != lastFitSize else {
                restorePositionOnce()
                return
            }
            lastFitSize = bounds.size
            suppressScaleSave = true
            pdfView.autoScales = true
            let fit = pdfView.scaleFactorForSizeToFit
            if fit.isFinite, fit > 0.05 {
                pdfView.scaleFactor = fit
            }
            pdfView.autoScales = true
            suppressScaleSave = false
            storeZoom(pdfView.scaleFactor, fit: .fitPage)
        case .fitWidth:
            guard bounds.size != lastFitSize else {
                restorePositionOnce()
                return
            }
            lastFitSize = bounds.size
            fitWidth()
        case .actual:
            guard lastFitSize == .zero else {
                restorePositionOnce()
                return
            }
            lastFitSize = bounds.size
            suppressScaleSave = true
            pdfView.autoScales = false
            pdfView.scaleFactor = 1
            suppressScaleSave = false
        case .custom:
            guard lastFitSize == .zero else {
                restorePositionOnce()
                return
            }
            lastFitSize = bounds.size
            suppressScaleSave = true
            pdfView.autoScales = false
            let scale = min(max(lockedZoom ?? session.zoom, 0.25), pdfView.maxScaleFactor)
            pdfView.scaleFactor = scale
            suppressScaleSave = false
        }
        // A deep link is applied after the scale change. Snapping back to the
        // pre-scale destination would put a vault link on the saved page.
        if stickJump == nil, let anchored {
            suppressScaleSave = true
            pdfView.go(to: anchored)
            suppressScaleSave = false
        }
        restorePositionOnce()
        if let stickJump {
            showJump(stickJump, flash: false)
        }
    }

    private func restorePositionOnce() {
        if let pending = session.pendingMarkReveal {
            guard pdfView.bounds.width > 160, pdfView.document != nil else { return }
            session.pendingMarkReveal = nil
            didRestorePosition = true
            reveal(pending)
            session.finishViewRestore()
            return
        }
        guard publishesPosition else {
            didRestorePosition = true
            return
        }
        guard !didRestorePosition else { return }
        guard pdfView.bounds.width > 160, pdfView.document != nil else { return }
        didRestorePosition = true
        if session.pendingReaderLink != nil {
            applyPendingLinkNow()
            session.finishViewRestore()
            return
        }
        if session.hasSavedViewState {
            let state = session.package.state
            reveal(ReadingPosition(page: state.page, scrollY: state.scrollY, zoom: nil))
        }
        session.finishViewRestore()
    }

    override func viewWillDisappear() {
        capturePositionForSave()
        super.viewWillDisappear()
    }

    func capturePositionForSave() {
        guard publishesPosition else { return }
        session.rememberScroll(currentPosition())
    }

    func freezeLayout() {
        lockedFit = session.fitMode
        lockedZoom = Double(pdfView.scaleFactor)
    }

    func publishCurrentPosition() {
        guard let page = pdfView.currentPage, let document = pdfView.document else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        let number = index + 1
        let section = session.outline.last { ($0.page ?? 0) <= number }?.title
        session.updatePage(number, count: document.pageCount, section: section)
        session.rememberZoom(Double(pdfView.scaleFactor), fit: lockedFit ?? session.fitMode)
        session.rememberScroll(currentPosition())
    }

    private func storeZoom(_ scale: CGFloat, fit: FitMode) {
        lockedFit = fit
        lockedZoom = Double(scale)
        guard publishesPosition else { return }
        session.rememberZoom(Double(scale), fit: fit)
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
        storeZoom(1, fit: .actual)
    }

    func zoomToFit() {
        suppressScaleSave = true
        pdfView.autoScales = true
        suppressScaleSave = false
        storeZoom(pdfView.scaleFactor, fit: .fitPage)
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
        storeZoom(pdfView.scaleFactor, fit: .fitWidth)
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
        storeZoom(pdfView.scaleFactor, fit: .custom)
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

    func setPaneActive(_ active: Bool) {
        titleStrip.setActive(active)
        refreshPaneTitle()
    }

    func focusFind() {
        setPaneActive(true)
        if findBar.stringValue.isEmpty { findBar.stringValue = session.findQuery }
        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.findBar)
            self.findBar.currentEditor()?.selectAll(nil)
        }
    }

    func toggleFind() {
        focusFind()
    }

    func setFindCount(_ text: String) {
        titleStrip.setCount(text)
    }

    private func refreshPaneTitle() {
        let title = session.bookURL.deletingPathExtension().lastPathComponent
        titleStrip.show(title: title, page: "p. \(displayedPageNumber())")
    }

    private func displayedPageNumber() -> Int {
        guard let page = pdfView.currentPage, let document = pdfView.document else { return session.page }
        let index = document.index(for: page)
        guard index != NSNotFound else { return session.page }
        return index + 1
    }

    func search(_ query: String, explicitAdvance: Bool = true) {
        ownsFindSession = true
        (view.window?.windowController as? ReaderWindowController)?.claimFindSession(from: self)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hasMatches = !matches.isEmpty && matches.first?.string?.localizedCaseInsensitiveContains(trimmed) == true
        let command = FindQuery.command(query: trimmed, previous: lastFindQuery, hasMatches: hasMatches, committed: findCommitted, explicitAdvance: explicitAdvance)
        findBar.stringValue = trimmed
        session.findQuery = trimmed
        switch command {
        case .begin:
            lastFindQuery = trimmed
            findCommitted = false
            startFind(trimmed)
        case .stay:
            findCommitted = true
        case .step:
            stepMatch(forward: true)
        }
    }

    @objc private func foundMatch(_ notification: Notification) {
        guard ownsFind(notification) else { return }
        guard let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
        matches.append(selection)
        publishHits()
    }

    @objc private func findFinished(_ notification: Notification) {
        guard ownsFind(notification) else { return }
        if pickInitialMatch, let document = pdfView.document {
            let pages = matches.map { pageNumber($0, in: document) }
            matchIndex = FindSelection.index(starts: pages, cursor: max(session.page, 1)) ?? 0
            pickInitialMatch = false
        }
        publishHits()
        showCurrentMatch()
    }

    private func ownsFind(_ notification: Notification) -> Bool {
        guard let document = pdfView.document else { return false }
        return ownsFindSession && (notification.object as? PDFDocument) === document
    }

    private func publishHits() {
        guard let document = pdfView.document else { return }
        session.searchHits = matches.enumerated().map { index, selection in
            let page = pageNumber(selection, in: document)
            let copy = selection.copy() as! PDFSelection
            copy.extendForLineBoundaries()
            let snippet = copy.string ?? selection.string ?? session.findQuery
            return SearchHit(id: index, page: page, snippet: snippet, section: session.outline.last { ($0.page ?? 0) <= page }?.title ?? "")
        }
        (view.window?.windowController as? ReaderWindowController)?.showFindCount(min(matchIndex + 1, max(matches.count, 1)), of: matches.count)
    }

    private func pageNumber(_ selection: PDFSelection, in document: PDFDocument) -> Int {
        guard let page = selection.pages.first else { return 1 }
        let index = document.index(for: page)
        guard index != NSNotFound, index >= 0, index < document.pageCount else { return 1 }
        return index + 1
    }

    private func showCurrentMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        session.searchIndex = matchIndex
        let selection = matches[matchIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.scrollSelectionToVisible(nil)
    }

    @objc private func findFromBar() {
        search(findBar.stringValue.isEmpty ? session.findQuery : findBar.stringValue, explicitAdvance: FindCommit.isExplicitAdvance())
    }
    func findNext() { stepMatch(forward: true) }
    func findPrevious() { stepMatch(forward: false) }

    private func startFind(_ query: String) {
        guard let document = pdfView.document else { return }
        matches = []
        matchIndex = 0
        pickInitialMatch = true
        session.searchHits = []
        if session.sidebar != .searchResults { session.sidebarBeforeSearch = session.sidebar }
        session.sidebar = .searchResults
        document.cancelFindString()
        document.beginFindString(query, withOptions: .caseInsensitive)
    }

    /// Find Next moves one match. A new search must not call this before the first hit is shown.
    private func stepMatch(forward: Bool) {
        let query = findBar.stringValue.isEmpty ? session.findQuery : findBar.stringValue
        session.findQuery = query
        ownsFindSession = true
        (view.window?.windowController as? ReaderWindowController)?.claimFindSession(from: self)
        guard !query.isEmpty else { return }
        if matches.isEmpty || matches.first?.string?.localizedCaseInsensitiveContains(query) != true {
            lastFindQuery = query
            findCommitted = false
            session.findQuery = query
            startFind(query)
            return
        }
        matchIndex = FindSelection.step(count: matches.count, current: matchIndex, forward: forward)
        session.searchIndex = matchIndex
        (view.window?.windowController as? ReaderWindowController)?.showFindCount(matchIndex + 1, of: matches.count)
        showCurrentMatch()
    }

    func captureSelection(showBar: Bool = true) {
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
        if showBar, session.settings.showSelectionBar, let union = selectionBounds(of: pdfView.currentSelection) {
            (view.window?.windowController as? ReaderWindowController)?.showSelectionBar(relativeTo: union, in: pdfView)
        }
    }

    private func selectionBounds(of selection: PDFSelection?) -> NSRect? {
        guard let selection else { return nil }
        var union: NSRect?
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let converted = pdfView.convert(line.bounds(for: page), from: page)
            guard converted.width > 0, converted.height > 0 else { continue }
            union = union.map { $0.union(converted) } ?? converted
        }
        return union
    }

    func refreshAnnotations() {
        applyDisplayedRotations()
        for annotation in annotations {
            annotation.page?.removeAnnotation(annotation)
        }
        annotations.removeAll()
        highlightIDs.removeAll()
        conceptIDs.removeAll()
        guard let document = pdfView.document else { return }
        for highlight in session.highlights {
            guard let pageNumber = highlight.page, let page = document.page(at: pageNumber - 1) else { continue }
            let rects = highlight.rects.isEmpty ? rectsFor(quote: highlight.quote, on: page) : highlight.rects
            for rect in rects {
                let bounds = NSRect(x: rect[0], y: rect.count > 1 ? rect[1] : 0, width: max((rect.count > 2 ? rect[2] : rect[0]) - rect[0], 4), height: max((rect.count > 3 ? rect[3] : rect[1]) - (rect.count > 1 ? rect[1] : 0), 4))
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if let parts = HighlightAppearance.components(color: highlight.color, dark: dark) {
                    annotation.color = NSColor(calibratedRed: parts.r, green: parts.g, blue: parts.b, alpha: parts.a)
                } else {
                    annotation.color = ReaderColor.nsColor(highlight.color).withAlphaComponent(HighlightAppearance.opacity)
                }
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
        addConceptMarkers(to: document)
        overlay.needsLayout = true
    }

    private func applyDisplayedRotations() {
        guard let document = pdfView.document else { return }
        for (key, rotation) in session.package.state.rotations {
            guard let number = Int(key), let page = document.page(at: number - 1) else { continue }
            if page.rotation != rotation { page.rotation = rotation }
        }
    }

    private func addConceptMarkers(to document: PDFDocument) {
        guard session.showConceptMarkers, !session.concepts.isEmpty else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let string = page.string else { continue }
            let section = session.outline.last { ($0.page ?? 0) <= index + 1 }?.title ?? ""
            let chapter = ChapterFiles.number(in: section)
            for concept in session.concepts where concept.chapter == nil || concept.chapter == chapter {
                for term in concept.findTerms {
                    guard concept.chapter == nil || concept.chapter == chapter,
                          let range = ConceptMatching.range(of: term, in: string),
                          let selection = page.selection(for: NSRange(range, in: string)) else { continue }
                    let bounds = selection.bounds(for: page)
                    let mark = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
                    mark.color = conceptColor(concept)
                    mark.contents = concept.id
                    page.addAnnotation(mark)
                    annotations.append(mark)
                    conceptIDs[ObjectIdentifier(mark)] = concept.id
                    let pageBounds = page.bounds(for: pdfView.displayBox)
                    let badge = PDFAnnotation(bounds: NSRect(x: pageBounds.maxX - 42, y: bounds.minY, width: 38, height: max(bounds.height, 12)), forType: .freeText, withProperties: nil)
                    badge.contents = concept.id
                    badge.font = NSFont.systemFont(ofSize: 8)
                    badge.color = conceptColor(concept).withAlphaComponent(0.18)
                    badge.fontColor = conceptColor(concept)
                    page.addAnnotation(badge)
                    annotations.append(badge)
                    conceptIDs[ObjectIdentifier(badge)] = concept.id
                    break
                }
            }
        }
    }

    private func conceptColor(_ concept: Concept) -> NSColor {
        switch MasteryFile.badge(session.mastery[concept.id]) {
        case .notStarted: return .secondaryLabelColor
        case .learning: return .systemBlue
        case .known: return .systemGreen
        case .due: return .systemOrange
        }
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
        // A destination puts this point at the top of the view. go(to:rect:) leaves
        // the page where it is when that corner is already barely on screen.
        let destination = PDFDestination(page: page, at: NSPoint(x: position.pdfX ?? bounds.minX, y: y))
        pdfView.go(to: destination)
    }

    /// Scrolls this pane only and flashes the quote for about a second.
    func showInPane(_ position: ReadingPosition) {
        reveal(position)
        guard let document = pdfView.document, let pageNumber = position.page, let page = document.page(at: pageNumber - 1) else { return }
        guard let quote = position.quote, let string = page.string, let range = string.range(of: quote), let selection = page.selection(for: NSRange(range, in: string)) else { return }
        pdfView.setCurrentSelection(selection, animate: true)
        let flash = PDFAnnotation(bounds: selection.bounds(for: page), forType: .highlight, withProperties: nil)
        flash.color = NSColor.systemYellow.withAlphaComponent(0.55)
        page.addAnnotation(flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            page.removeAnnotation(flash)
        }
    }

    var noteHostView: NSView { pdfView }

    func noteRect(for id: String) -> NSRect? {
        guard let item = session.annotations.first(where: { $0.id == id || $0.highlight?.id == id || $0.note?.id == id }),
              let pageNumber = item.page,
              let page = pdfView.document?.page(at: pageNumber - 1) else { return nil }
        if let string = page.string, let range = string.range(of: item.quote), let selection = page.selection(for: NSRange(range, in: string)) {
            return pdfView.convert(selection.bounds(for: page), from: page)
        }
        return pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
    }

    func consumePendingJump() {
        guard session.pendingReaderLink != nil, !applyingJump else { return }
        guard view.window != nil, pdfView.bounds.width > 160, pdfView.document != nil else { return }
        // The opening fit ends in `restorePositionOnce`. Applying the link earlier
        // lets that fit put the saved page back on screen.
        if !didRestorePosition { return }
        applyPendingLinkNow()
    }

    private func applyPendingLinkNow() {
        guard !applyingJump, let link = session.pendingReaderLink else { return }
        guard let jump = PDFJumpResolver.resolve(link: link, highlights: session.highlights, notes: session.notes) else {
            session.pendingReaderLink = nil
            return
        }
        session.pendingReaderLink = nil
        if !didFinishOpeningLayout {
            stickJump = jump
        }
        showJump(jump, flash: true)
    }

    private func showJump(_ jump: PDFJump, flash: Bool) {
        guard !applyingJump, let document = pdfView.document else { return }
        let index = min(max(jump.page - 1, 0), max(document.pageCount - 1, 0))
        guard let page = document.page(at: index) else { return }
        applyingJump = true
        defer { applyingJump = false }
        if let rect = unionRect(jump.rects) {
            pdfView.go(to: rect, on: page)
            if flash { flashRect(rect, on: page) }
        } else if let quote = jump.quote, let string = page.string, let range = string.range(of: quote), let selection = page.selection(for: NSRange(range, in: string)) {
            pdfView.go(to: selection)
            pdfView.setCurrentSelection(selection, animate: false)
            if flash { flashRect(selection.bounds(for: page), on: page) }
        } else {
            reveal(ReadingPosition(page: document.index(for: page) + 1, scrollY: jump.scrollY, pdfY: jump.pdfY))
        }
        let number = document.index(for: page) + 1
        let section = session.outline.last { ($0.page ?? 0) <= number }?.title
        session.updatePage(number, count: document.pageCount, section: section)
        if didFinishOpeningLayout {
            stickJump = nil
        }
    }

    private func unionRect(_ rects: [[Double]]) -> NSRect? {
        var result: NSRect?
        for rect in rects where rect.count >= 4 {
            let width = rect[2] - rect[0]
            let height = rect[3] - rect[1]
            guard width > 0.5, height > 0.5 else { continue }
            let next = NSRect(x: rect[0], y: rect[1], width: width, height: height)
            result = result.map { $0.union(next) } ?? next
        }
        return result
    }

    private func flashRect(_ rect: NSRect, on page: PDFPage) {
        let flash = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        flash.color = NSColor.systemYellow.withAlphaComponent(0.55)
        page.addAnnotation(flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            page.removeAnnotation(flash)
        }
    }

    private func conceptID(atViewPoint point: NSPoint) -> String? {
        guard let page = pdfView.page(for: point, nearest: true) else { return nil }
        let pagePoint = pdfView.convert(point, to: page)
        for annotation in page.annotations where annotation.bounds.contains(pagePoint) {
            if let id = conceptIDs[ObjectIdentifier(annotation)] { return id }
        }
        return nil
    }

    private func presentConcept(_ id: String) {
        guard let concept = session.concepts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "\(concept.id) \(concept.title)"
        var detail: [String] = []
        if let claim = concept.claim { detail.append("Claim: \(claim)") }
        if let trap = concept.trap { detail.append("Trap: \(trap)") }
        alert.informativeText = detail.joined(separator: "\n")
        alert.addButton(withTitle: "Ask tutor about this")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            session.askAboutConcept(concept)
        }
    }

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
        overlay.needsLayout = true
        refreshPaneTitle()
        guard publishesPosition else { return }
        guard let page = pdfView.currentPage, let document = pdfView.document else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        let number = index + 1
        let section = session.outline.last { ($0.page ?? 0) <= number }?.title
        session.updatePage(number, count: document.pageCount, section: section)
        session.rememberScroll(currentPosition())
    }

    @objc private func scrolled() {
        if publishesPosition { session.rememberScroll(currentPosition()) }
        (view.window?.windowController as? ReaderWindowController)?.dismissSelectionBar()
    }

    @objc private func scaleChanged() {
        guard !suppressScaleSave else { return }
        guard pdfView.bounds.width > 160, pdfView.bounds.height > 160 else { return }
        overlay.needsLayout = true
        let scale = pdfView.scaleFactor
        guard scale.isFinite, scale > 0.05 else { return }
        if pdfView.autoScales {
            storeZoom(scale, fit: .fitPage)
        } else if (lockedFit ?? session.fitMode) == .fitWidth {
            storeZoom(scale, fit: .fitWidth)
        } else if abs(scale - 1) < 0.001 && (lockedFit ?? session.fitMode) == .actual {
            storeZoom(1, fit: .actual)
        } else {
            storeZoom(scale, fit: .custom)
        }
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
    weak var session: ReaderSession?
    var onMouseUp: (() -> Void)?
    var highlightIDAt: ((NSPoint) -> String?)?
    var onRemoveHighlight: ((String) -> Void)?
    var onOpenHighlight: ((String) -> Void)?
    var conceptAt: ((NSPoint) -> String?)?
    var onConcept: ((String) -> Void)?
    var prepareSelection: (() -> Void)?
    var beginFind: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if let id = highlightIDAt?(point) {
            onOpenHighlight?(id)
            return
        }
        if let id = conceptAt?(point) {
            onConcept?(id)
            return
        }
        onMouseUp?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = highlightIDAt?(point) {
            let menu = NSMenu()
            let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            let colors = NSMenu()
            for index in 1...6 {
                let item = NSMenuItem(title: HighlightCallout.name(for: index).capitalized, action: #selector(recolorClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.tag = index
                colors.addItem(item)
            }
            color.submenu = colors
            menu.addItem(color)
            let note = NSMenuItem(title: "Add/Edit Note", action: #selector(noteClicked(_:)), keyEquivalent: "")
            note.target = self
            note.representedObject = id
            menu.addItem(note)
            let copy = NSMenuItem(title: "Copy", action: #selector(copyHighlightClicked(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = id
            menu.addItem(copy)
            let link = NSMenuItem(title: "Copy Link", action: #selector(copyLinkClicked(_:)), keyEquivalent: "")
            link.target = self
            link.representedObject = id
            menu.addItem(link)
            if session?.annotations.first(where: { $0.id == id })?.hasNote == true {
                let removeNote = NSMenuItem(title: "Remove Note", action: #selector(removeNoteClicked(_:)), keyEquivalent: "")
                removeNote.target = self
                removeNote.representedObject = id
                menu.addItem(removeNote)
            }
            let remove = NSMenuItem(title: "Remove Highlight & Note", action: #selector(removeHighlightClicked(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = id
            menu.addItem(remove)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        if highlightIDAt?(point) != nil { return nil }
        prepareSelection?()
        guard let session, let text = session.selection?.text, !text.isEmpty else { return super.menu(for: event) }
        for title in ["Highlight", "Note", "Look Up", "Ask AI", "Copy"] {
            let item = NSMenuItem(title: title, action: #selector(selectionMenu(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let word = text.split(separator: " ").first.map(String.init) ?? text
        let lookup = NSMenuItem(title: "Look Up “\(word)”", action: #selector(selectionMenu(_:)), keyEquivalent: "")
        lookup.target = self
        menu.addItem(lookup)
        let link = NSMenuItem(title: "Copy Link to Selection", action: #selector(selectionMenu(_:)), keyEquivalent: "")
        link.target = self
        menu.addItem(link)
        let search = NSMenuItem(title: "Search for “\(text.prefix(40))”", action: #selector(selectionMenu(_:)), keyEquivalent: "")
        search.target = self
        menu.addItem(search)
        return menu
    }

    @objc private func selectionMenu(_ sender: NSMenuItem) {
        guard let session else { return }
        let title = sender.title
        if title == "Highlight" { session.highlight(color: session.package.state.lastHighlightColor) }
        else if title == "Note" { session.addNote() }
        else if title.hasPrefix("Look Up") { session.lookUp() }
        else if title == "Ask AI" { session.show(tab: .askAI) }
        else if title == "Copy" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.selection?.text ?? "", forType: .string)
        } else if title == "Copy Link to Selection" {
            let link = CopyLink.make(path: session.bookURL.path, page: session.selection?.page, cfi: session.selection?.cfi, quote: session.selection?.text ?? "")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.url, forType: .string)
        } else if title.hasPrefix("Search") {
            session.findQuery = session.selection?.text ?? ""
            beginFind?()
        }
    }

    @objc private func recolorClicked(_ sender: NSMenuItem) {
        guard let session, let id = sender.representedObject as? String else { return }
        session.recolorAnnotation(id: id, color: sender.tag)
    }

    @objc private func noteClicked(_ sender: NSMenuItem) {
        guard let session, let id = sender.representedObject as? String else { return }
        session.openAnnotation(id)
    }

    @objc private func copyHighlightClicked(_ sender: NSMenuItem) {
        guard let session, let id = sender.representedObject as? String, let quote = session.annotations.first(where: { $0.id == id })?.quote else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quote, forType: .string)
    }

    @objc private func copyLinkClicked(_ sender: NSMenuItem) {
        guard let session, let id = sender.representedObject as? String, let item = session.annotations.first(where: { $0.id == id }) else { return }
        let link = CopyLink.make(path: session.bookURL.path, page: item.page, cfi: item.cfi, quote: item.quote)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
    }

    @objc private func removeNoteClicked(_ sender: NSMenuItem) {
        guard let session, let id = sender.representedObject as? String else { return }
        session.removeNoteOnly(id: id)
    }

    @objc private func removeHighlightClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRemoveHighlight?(id)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }
}

final class NoteOverlay: NSView {
    weak var pdfView: PDFView?
    weak var session: ReaderSession?
    private var glyphs: [String: NSImageView] = [:]
    private var cards: [String: NSTextField] = [:]

    override var tag: Int { 77 }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        guard let pdfView, let session, let document = pdfView.document else { return }
        let notes = session.annotations.filter(\.hasNote)
        let live = Set(notes.map(\.id))
        for (id, view) in glyphs where !live.contains(id) { view.removeFromSuperview(); glyphs[id] = nil }
        for (id, view) in cards where !live.contains(id) { view.removeFromSuperview(); cards[id] = nil }
        let visible = Set(pdfView.visiblePages.map { document.index(for: $0) + 1 })
        var cardSlots: [(id: String, y: Double)] = []
        var cardWidths: [String: CGFloat] = [:]
        var cardX: [String: CGFloat] = [:]
        for item in notes {
            guard let pageNumber = item.page, visible.contains(pageNumber), let page = document.page(at: pageNumber - 1) else { continue }
            let passage = rect(for: item, on: page, pdfView: pdfView) ?? pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            let pageRect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            let margin = bounds.maxX - pageRect.maxX
            let showCard = session.showMarginNotes && margin >= 180
            let glyph = glyphs[item.id] ?? makeGlyph(item)
            glyphs[item.id] = glyph
            if margin < 18 {
                let pageBounds = page.bounds(for: pdfView.displayBox)
                let marker = NSRect(x: pageBounds.maxX - 16, y: pageBounds.midY, width: 14, height: 14)
                let converted = pdfView.convert(marker, from: page)
                glyph.frame = NSRect(x: converted.minX, y: passage.maxY - 16, width: 14, height: 14)
            } else {
                glyph.frame = NSRect(x: min(pageRect.maxX + 4, bounds.maxX - 18), y: passage.maxY - 16, width: 14, height: 14)
            }
            glyph.toolTip = item.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.quote
            if showCard {
                let card = cards[item.id] ?? makeCard(item)
                cards[item.id] = card
                card.stringValue = item.body
                cardSlots.append((id: item.id, y: Double(passage.maxY - 54)))
                cardX[item.id] = pageRect.maxX + 22
                cardWidths[item.id] = min(margin - 28, 220)
            } else {
                cards[item.id]?.removeFromSuperview()
                cards[item.id] = nil
            }
        }
        for placed in MarginLayout.stack(cardSlots, height: 54) {
            guard let card = cards[placed.id] else { continue }
            card.frame = NSRect(x: cardX[placed.id] ?? 0, y: placed.y, width: cardWidths[placed.id] ?? 180, height: 54)
        }
    }

    private func makeGlyph(_ item: Annotation) -> NSImageView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "Note")
        image.contentTintColor = ReaderColor.nsColor(item.color)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.identifier = NSUserInterfaceItemIdentifier(item.id)
        let click = NSClickGestureRecognizer(target: self, action: #selector(open(_:)))
        image.addGestureRecognizer(click)
        addSubview(image)
        return image
    }

    private func makeCard(_ item: Annotation) -> NSTextField {
        let field = NSTextField(labelWithString: item.body)
        field.font = .systemFont(ofSize: 11)
        field.maximumNumberOfLines = 3
        field.lineBreakMode = .byTruncatingTail
        field.textColor = .labelColor
        field.identifier = NSUserInterfaceItemIdentifier(item.id)
        let click = NSClickGestureRecognizer(target: self, action: #selector(openCard(_:)))
        field.addGestureRecognizer(click)
        addSubview(field)
        return field
    }

    private func rect(for item: Annotation, on page: PDFPage, pdfView: PDFView) -> NSRect? {
        if let stored = item.rects.first, stored.count >= 4 {
            let bounds = NSRect(x: stored[0], y: stored[1], width: stored[2] - stored[0], height: stored[3] - stored[1])
            return pdfView.convert(bounds, from: page)
        }
        guard let string = page.string, let range = string.range(of: item.quote), let selection = page.selection(for: NSRange(range, in: string)) else { return nil }
        return pdfView.convert(selection.bounds(for: page), from: page)
    }

    @objc private func openCard(_ sender: NSClickGestureRecognizer) {
        guard let id = (sender.view as? NSTextField)?.identifier?.rawValue else { return }
        session?.lastAnnotationHit = id
        session?.openAnnotation(id)
    }

    @objc private func open(_ sender: NSClickGestureRecognizer) {
        guard let id = (sender.view as? NSImageView)?.identifier?.rawValue else { return }
        session?.lastAnnotationHit = id
        session?.openAnnotation(id)
    }
}
