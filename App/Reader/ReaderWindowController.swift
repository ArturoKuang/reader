import AppKit
import ReaderCore
import SwiftUI

final class ReaderWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let session: ReaderSession
    private let split = NSSplitViewController()
    private let sidebarHost: NSHostingController<SidebarView>
    private let panelHost: NSHostingController<RightPanelView>
    private let center: NSViewController
    private var pdfController: PDFContainerViewController?
    private var epubController: EPUBContainerViewController?
    private var keyMonitor: Any?
    private var sidebarItem: NSSplitViewItem?
    private var panelItem: NSSplitViewItem?
    private var slideshowTimer: Timer?
    private var reappliedSavedFrame = false
    private var previousSidebar: SidebarMode = .thumbnails
    private let toastView = PassThroughView()
    private let toastLabel = NSTextField(labelWithString: "")

    init(session: ReaderSession) {
        self.session = session
        sidebarHost = NSHostingController(rootView: SidebarView(session: session))
        panelHost = NSHostingController(rootView: RightPanelView(session: session))
        if session.isPDF {
            let pdf = PDFContainerViewController(session: session)
            pdfController = pdf
            center = pdf
        } else {
            let epub = EPUBContainerViewController(session: session)
            epubController = epub
            center = epub
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        super.init(window: window)
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 480)
        restoreWindowFrame(window)
        configureSplit()
        configureToolbar()
        installToast()
        session.onToast = { [weak self] text in
            self?.presentToast(text)
        }
        session.onCaptureSelection = { [weak self] done in
            guard let self else { done(); return }
            if let epub = self.epubController {
                epub.captureSelection(completion: done)
            } else {
                self.pdfController?.captureSelection()
                done()
            }
        }
        installMonitor()
        session.onPageChange = { [weak self] in
            self?.document.map { ($0 as? ReaderDocument)?.refreshSubtitle() }
            self?.pdfController?.consumePendingJump()
            self?.epubController?.consumePendingJump()
        }
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configureSplit() {
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 280
        sidebar.canCollapse = true
        // Full-height sidebar draws under the title bar, beside the traffic lights.
        sidebar.allowsFullHeightLayout = true
        sidebarHost.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let content = NSSplitViewItem(viewController: center)
        content.minimumThickness = 320
        content.allowsFullHeightLayout = true
        let inspector = NSSplitViewItem(viewController: panelHost)
        inspector.minimumThickness = 280
        inspector.maximumThickness = 320
        inspector.canCollapse = true
        inspector.allowsFullHeightLayout = true
        split.splitView.dividerStyle = .thin
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(content)
        split.addSplitViewItem(inspector)
        sidebarItem = sidebar
        panelItem = inspector
        window?.contentViewController = split
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }

    private func installToast() {
        guard let content = window?.contentView else { return }
        toastView.wantsLayer = true
        toastView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        toastView.layer?.cornerRadius = 8
        toastView.translatesAutoresizingMaskIntoConstraints = false
        toastView.isHidden = true
        toastLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        toastLabel.textColor = .white
        toastLabel.alignment = .center
        toastLabel.drawsBackground = false
        toastLabel.isBezeled = false
        toastLabel.isEditable = false
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(toastLabel)
        content.addSubview(toastView)
        NSLayoutConstraint.activate([
            toastLabel.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -14),
            toastLabel.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 8),
            toastLabel.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -8),
            toastView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toastView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -32),
        ])
    }

    private func presentToast(_ text: String?) {
        let message = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else {
            toastView.isHidden = true
            return
        }
        toastLabel.stringValue = message
        toastView.isHidden = false
        window?.contentView?.addSubview(toastView, positioned: .above, relativeTo: nil)
    }

    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if self.slideshowTimer != nil, event.keyCode == 53 {
                self.stopSlideshow()
                return nil
            }
            let position = self.pdfController?.currentPosition() ?? self.epubController?.currentPosition() ?? ReadingPosition(page: self.session.page, zoom: self.session.zoom)
            let handled = self.session.handleMarkEvent(event, documentFocused: true, position: position)
            if handled.consumed {
                if let jump = handled.jump {
                    self.reveal(jump)
                }
                return nil
            }
            return event
        }
    }

    private func restoreWindowFrame(_ window: NSWindow) {
        guard session.hasSavedViewState, let frame = session.package.state.windowFrame else { return }
        let rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        guard rect.width > 400, rect.height > 300 else { return }
        window.setFrame(rect, display: false)
    }

    private func storeWindowFrame() {
        guard let frame = window?.frame else { return }
        session.noteWindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !reappliedSavedFrame else { return }
        reappliedSavedFrame = true
        guard let window else { return }
        restoreWindowFrame(window)
    }

    func windowDidResize(_ notification: Notification) {
        pdfController?.applyFittingScale()
        storeWindowFrame()
    }

    func windowDidMove(_ notification: Notification) {
        storeWindowFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        pdfController?.applyFittingScale(force: true)
        storeWindowFrame()
        session.saveViewNow()
    }

    func windowWillClose(_ notification: Notification) {
        storeWindowFrame()
        pdfController?.capturePositionForSave()
        session.saveViewNow()
    }

    func applyChrome() {
        let contact = session.sidebar == .contactSheet
        sidebarItem?.isCollapsed = session.sidebar == .hidden || contact
        panelItem?.isCollapsed = !session.panelVisible
        pdfController?.setContactSheet(contact)
        epubController?.setContactSheet(contact)
        sidebarHost.rootView = SidebarView(session: session)
        panelHost.rootView = RightPanelView(session: session)
    }

    func reveal(_ position: ReadingPosition) {
        if session.isPDF {
            pdfController?.reveal(position)
        } else {
            epubController?.reveal(position)
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        slideshowTimer?.invalidate()
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarModes, .sidebarTrackingSeparator, .backForward, .flexibleSpace, .search, .inspector]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarModes, .sidebarTrackingSeparator, .backForward, .flexibleSpace, .search, .inspector]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarModes:
            // Before the sidebar-tracking separator, so this capsule stays in the sidebar title bar.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = sidebarModeControl()
            item.label = "Sidebar"
            return item
        case .backForward:
            // After the separator: its own capsule at the leading edge of the document.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = backForwardControl()
            item.label = "History"
            item.isNavigational = true
            return item
        case .sidebarTrackingSeparator:
            return nil
        case .search:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find")
            item.action = #selector(find(_:))
            item.target = self
            item.label = "Find"
            return item
        case .inspector:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Inspector")
            item.action = #selector(togglePanel(_:))
            item.target = self
            item.label = "Inspector"
            return item
        default:
            return nil
        }
    }

    private func sidebarModeControl() -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .momentary
        control.segmentStyle = .separated
        control.setImage(NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle sidebar"), forSegment: 0)
        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Sidebar options")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        control.setImage(chevron, forSegment: 1)
        control.setWidth(32, forSegment: 0)
        control.setWidth(22, forSegment: 1)
        control.target = self
        control.action = #selector(sidebarSegmentClicked(_:))
        return control
    }

    private func backForwardControl() -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .momentary
        control.segmentStyle = .separated
        control.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back"), forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward"), forSegment: 1)
        control.setWidth(36, forSegment: 0)
        control.setWidth(36, forSegment: 1)
        control.target = self
        control.action = #selector(backForwardClicked(_:))
        return control
    }

    @objc private func sidebarSegmentClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            toggleSidebar(sender)
            return
        }
        let menu = sidebarMenu()
        let origin = NSPoint(x: sender.width(forSegment: 0), y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func backForwardClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            goBack(sender)
        } else {
            goForward(sender)
        }
    }

    private func sidebarMenu() -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, Selector, SidebarMode?)] = [
            ("Hide Sidebar", #selector(hideSidebar(_:)), .hidden),
            ("Thumbnails", #selector(showThumbnails(_:)), .thumbnails),
            ("Table of Contents", #selector(showContents(_:)), .tableOfContents),
            ("Highlights and Notes", #selector(showHighlightsAndNotes(_:)), .highlightsAndNotes),
            ("Bookmarks", #selector(showBookmarks(_:)), .bookmarks),
        ]
        for entry in entries {
            let item = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: "")
            item.target = self
            item.state = session.sidebar == entry.2 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for mode in ReadingLayout.allCases {
            let item = NSMenuItem(title: mode.title, action: mode.action, keyEquivalent: "")
            item.target = self
            item.state = readingLayout == mode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: View menu

    @objc func hideSidebar(_ sender: Any?) { session.setSidebar(.hidden); applyChrome() }
    @objc func showThumbnails(_ sender: Any?) { session.setSidebar(.thumbnails); applyChrome() }
    @objc func showContents(_ sender: Any?) { session.setSidebar(.tableOfContents); applyChrome() }
    @objc func showHighlightsAndNotes(_ sender: Any?) { session.setSidebar(.highlightsAndNotes); applyChrome() }
    @objc func showBookmarks(_ sender: Any?) { session.setSidebar(.bookmarks); applyChrome() }
    @objc func showContactSheet(_ sender: Any?) {
        if session.sidebar != .contactSheet { previousSidebar = session.sidebar }
        session.setSidebar(.contactSheet)
        applyChrome()
    }
    @objc func toggleSidebar(_ sender: Any?) {
        if session.sidebar == .hidden {
            session.setSidebar(previousSidebar == .hidden ? .thumbnails : previousSidebar)
        } else if session.sidebar == .contactSheet {
            session.setSidebar(previousSidebar == .contactSheet ? .thumbnails : previousSidebar)
        } else {
            previousSidebar = session.sidebar
            session.setSidebar(.hidden)
        }
        applyChrome()
    }
    @objc func toggleContinuous(_ sender: Any?) { chooseLayout(.continuous) }
    @objc func singlePage(_ sender: Any?) { chooseLayout(.single) }
    @objc func twoPages(_ sender: Any?) { chooseLayout(.twoPages) }

    private func chooseLayout(_ layout: ReadingLayout) {
        if session.sidebar == .contactSheet {
            let back = previousSidebar == .hidden || previousSidebar == .contactSheet ? SidebarMode.thumbnails : previousSidebar
            session.setSidebar(back)
        }
        switch layout {
        case .continuous:
            session.setTwoPages(false)
            session.setContinuous(true)
        case .single:
            session.setTwoPages(false)
            session.setContinuous(false)
        case .twoPages:
            session.setContinuous(false)
            session.setTwoPages(true)
        case .contact:
            break
        }
        pdfController?.applyDisplayMode()
        epubController?.applyDisplayMode()
        applyChrome()
    }
    @objc func actualSize(_ sender: Any?) { pdfController?.actualSize(); epubController?.actualSize() }
    @objc func zoomToFit(_ sender: Any?) { pdfController?.zoomToFit(); epubController?.zoomToFit() }
    @objc func fitWidth(_ sender: Any?) { pdfController?.fitWidth(); epubController?.fitWidth() }
    @objc func zoomIn(_ sender: Any?) { pdfController?.zoomIn(); epubController?.zoom(by: 1.15) }
    @objc func zoomOut(_ sender: Any?) { pdfController?.zoomOut(); epubController?.zoom(by: 1 / 1.15) }
    @objc func zoomToSelection(_ sender: Any?) { pdfController?.zoomToSelection() }
    @objc func rotateLeft(_ sender: Any?) { session.rotate(clockwise: false); pdfController?.refreshAnnotations() }
    @objc func rotateRight(_ sender: Any?) { session.rotate(clockwise: true); pdfController?.refreshAnnotations() }
    @objc func togglePanel(_ sender: Any?) { session.togglePanel(); applyChrome() }
    @objc func showNotesTab(_ sender: Any?) { session.show(tab: .notes); applyChrome() }
    @objc func showWordsTab(_ sender: Any?) { session.show(tab: .words); applyChrome() }
    @objc func showHighlightsTab(_ sender: Any?) { session.show(tab: .highlights); applyChrome() }
    @objc func showAskTab(_ sender: Any?) { session.show(tab: .askAI); applyChrome() }
    @objc func expandAllNotes(_ sender: Any?) { session.expandAllNotes(); pdfController?.refreshAnnotations(); applyChrome() }
    @objc func collapseAllNotes(_ sender: Any?) { session.collapseAllNotes(); pdfController?.refreshAnnotations(); applyChrome() }
    @objc func slideshow(_ sender: Any?) {
        if slideshowTimer != nil { stopSlideshow(); return }
        window?.toggleFullScreen(nil)
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.nextPage(nil)
        }
    }
    private func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }

    @objc func goBack(_ sender: Any?) {
        if let pdf = pdfController, pdf.goBack() { return }
        guard let position = session.backPosition(current: pdfController?.currentPosition() ?? epubController?.currentPosition() ?? ReadingPosition(page: session.page)) else { return }
        reveal(position)
    }
    @objc func goForward(_ sender: Any?) {
        if let pdf = pdfController, pdf.goForward() { return }
        guard let position = session.forwardPosition(current: pdfController?.currentPosition() ?? epubController?.currentPosition() ?? ReadingPosition(page: session.page)) else { return }
        reveal(position)
    }
    @objc func nextPage(_ sender: Any?) { pdfController?.nextPage(); epubController?.nextPage() }
    @objc func previousPage(_ sender: Any?) { pdfController?.previousPage(); epubController?.previousPage() }
    @objc func goToPage(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Page"
        alert.informativeText = session.isPDF ? "Enter a page from 1 to \(session.pageCount)." : "Enter a section number."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = "\(session.page)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let page = Int(field.stringValue) else { return }
            self?.reveal(ReadingPosition(page: page))
        }
    }

    @objc func find(_ sender: Any?) { pdfController?.toggleFind(); epubController?.toggleFind() }
    @objc func findNext(_ sender: Any?) { pdfController?.findNext(); epubController?.find(forward: true) }
    @objc func findPrevious(_ sender: Any?) { pdfController?.findPrevious(); epubController?.find(forward: false) }

    @objc func highlight1(_ sender: Any?) { highlight(1) }
    @objc func highlight2(_ sender: Any?) { highlight(2) }
    @objc func highlight3(_ sender: Any?) { highlight(3) }
    @objc func highlight4(_ sender: Any?) { highlight(4) }
    @objc func highlight5(_ sender: Any?) { highlight(5) }
    @objc func highlight6(_ sender: Any?) { highlight(6) }
    @objc func highlightLast(_ sender: Any?) { session.highlightLast(); pdfController?.refreshAnnotations(); applyChrome() }
    private func highlight(_ color: Int) {
        session.withSelection { [weak self] in
            guard let self else { return }
            self.session.highlight(color: color)
            self.pdfController?.refreshAnnotations()
            self.applyChrome()
        }
    }
    @objc func addNote(_ sender: Any?) {
        session.withSelection { [weak self] in
            guard let self else { return }
            self.session.addNote()
            self.pdfController?.refreshAnnotations()
            self.applyChrome()
        }
    }
    @objc func lookUp(_ sender: Any?) {
        session.withSelection { [weak self] in
            guard let self else { return }
            self.session.lookUp()
            self.pdfController?.showLookup()
            self.applyChrome()
        }
    }
    @objc func askAI(_ sender: Any?) {
        session.withSelection { [weak self] in
            guard let self else { return }
            self.session.show(tab: .askAI)
            self.applyChrome()
        }
    }
    @objc func explainSimply(_ sender: Any?) {
        session.withSelection { [weak self] in
            guard let self else { return }
            self.session.ask(purpose: .explainSimply)
            self.applyChrome()
        }
    }
    @objc func summarizeSection(_ sender: Any?) {
        session.withSelection { [weak self] in
            guard let self else { return }
            self.session.ask(purpose: .summarizeSection)
            self.applyChrome()
        }
    }
    @objc func bookmarkPage(_ sender: Any?) { session.addBookmark(); applyChrome() }
    @objc func revealInObsidian(_ sender: Any?) {
        guard session.usesVault, let vault = session.vaultName, let root = session.vaultRoot, let folder = session.bookFolder else { return }
        let chapter = ChapterFiles.number(in: session.selection?.section ?? session.sectionTitle)
        let name = ChapterFiles.notesFile(chapter: chapter, bookTitle: session.bookURL.deletingPathExtension().lastPathComponent)
        var relative = folder
        if relative.hasPrefix(root) {
            relative = String(relative.dropFirst(root.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
        }
        let file = Paths.join(Paths.join(relative, "notes"), name)
        let block = session.notes.last?.id ?? session.highlights.last?.id
        if let url = URL(string: ObsidianLink.open(vault: vault, file: file, blockID: block)) {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func toggleConceptMarkers(_ sender: Any?) {
        session.showConceptMarkers.toggle()
        session.onAnnotationsChanged?()
        session.onSaveVaultState?()
    }
    @objc func copyCitation(_ sender: Any?) {
        session.withSelection { [weak self] in
            guard let self, let text = self.session.copyCitation() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(hideSidebar(_:)): menuItem.state = session.sidebar == .hidden ? .on : .off
        case #selector(showThumbnails(_:)): menuItem.state = session.sidebar == .thumbnails ? .on : .off
        case #selector(showContents(_:)): menuItem.state = session.sidebar == .tableOfContents ? .on : .off
        case #selector(showHighlightsAndNotes(_:)): menuItem.state = session.sidebar == .highlightsAndNotes ? .on : .off
        case #selector(showBookmarks(_:)): menuItem.state = session.sidebar == .bookmarks ? .on : .off
        case #selector(toggleContinuous(_:)): menuItem.state = readingLayout == .continuous ? .on : .off
        case #selector(singlePage(_:)): menuItem.state = readingLayout == .single ? .on : .off
        case #selector(twoPages(_:)): menuItem.state = readingLayout == .twoPages ? .on : .off
        case #selector(showContactSheet(_:)): menuItem.state = readingLayout == .contact ? .on : .off
        case #selector(togglePanel(_:)): menuItem.state = session.panelVisible ? .on : .off
        case #selector(toggleConceptMarkers(_:)): menuItem.state = session.showConceptMarkers ? .on : .off
        default: break
        }
        return true
    }
}

private enum ReadingLayout: CaseIterable {
    case continuous, single, twoPages, contact

    var title: String {
        switch self {
        case .continuous: return "Continuous Scroll"
        case .single: return "Single Page"
        case .twoPages: return "Two Pages"
        case .contact: return "Contact Sheet"
        }
    }

    var action: Selector {
        switch self {
        case .continuous: return #selector(ReaderWindowController.toggleContinuous(_:))
        case .single: return #selector(ReaderWindowController.singlePage(_:))
        case .twoPages: return #selector(ReaderWindowController.twoPages(_:))
        case .contact: return #selector(ReaderWindowController.showContactSheet(_:))
        }
    }
}

private extension ReaderWindowController {
    var readingLayout: ReadingLayout {
        if session.sidebar == .contactSheet { return .contact }
        if session.twoPages { return .twoPages }
        if session.continuous { return .continuous }
        return .single
    }
}

private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension NSToolbarItem.Identifier {
    static let sidebarModes = NSToolbarItem.Identifier("sidebarModes")
    static let backForward = NSToolbarItem.Identifier("backForward")
    static let search = NSToolbarItem.Identifier("search")
    static let inspector = NSToolbarItem.Identifier("inspector")
}
