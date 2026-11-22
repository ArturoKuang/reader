import AppKit
import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

final class ReaderWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, NSSearchFieldDelegate {
    let session: ReaderSession
    private let split = NSSplitViewController()
    private var searchItem: NSSearchToolbarItem?
    private let findCountLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()
    private var inspectorObservation: NSKeyValueObservation?
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
    private let notePopover = NotePopoverController()
    private let selectionBar = SelectionBarController()
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
        session.onPresentNote = { [weak self] id in
            self?.presentNote(id)
        }
        session.onRevealInObsidian = { [weak self] id in
            self?.revealObsidian(id: id)
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
        let inspector = NSSplitViewItem(inspectorWithViewController: panelHost)
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
        inspectorObservation = inspector.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            self.session.panelVisible = !item.isCollapsed
            self.session.package.state.panelVisible = self.session.panelVisible
        }
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
            if event.keyCode == 53 {
                self.dismissSelectionBar()
                if self.session.sidebar == .searchResults {
                    self.session.sidebar = self.session.sidebarBeforeSearch ?? .thumbnails
                    self.session.searchHits = []
                    self.applyChrome()
                    return nil
                }
            }
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
        offerVaultSave()
        showTipStrip()
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
        if session.isPDF, let toolbar = window?.toolbar, let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .appearance }) {
            toolbar.removeItem(at: index)
        }
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
        [.sidebarModes, .sidebarTrackingSeparator, .backForward, .highlight, .addNote, .zoomOut, .zoomIn, .appearance, .flexibleSpace, .search, .findCount, .vault, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarModes, .sidebarTrackingSeparator, .backForward, .highlight, .addNote, .zoomOut, .zoomIn, .appearance, .flexibleSpace, .search, .findCount, .vault, .inspectorTrackingSeparator, .toggleInspector]
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
        case .appearance:
            guard !session.isPDF else { return nil }
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: "Appearance")
            item.label = "Appearance"
            item.menu = appearanceMenu()
            return item
        case .addNote:
            let note = NSToolbarItem(itemIdentifier: itemIdentifier)
            note.image = NSImage(systemSymbolName: "note.text.badge.plus", accessibilityDescription: "Add Note")
            note.action = #selector(addNote(_:))
            note.target = self
            note.label = "Add Note"
            return note
        case .zoomIn:
            let zoom = NSToolbarItem(itemIdentifier: itemIdentifier)
            zoom.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In")
            zoom.action = #selector(zoomIn(_:))
            zoom.target = self
            zoom.label = "Zoom In"
            return zoom
        case .zoomOut:
            let zoom = NSToolbarItem(itemIdentifier: itemIdentifier)
            zoom.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out")
            zoom.action = #selector(zoomOut(_:))
            zoom.target = self
            zoom.label = "Zoom Out"
            return zoom
        case .highlight:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = highlightControl()
            item.label = "Highlight"
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Find"
            item.searchField.target = self
            item.searchField.action = #selector(submitSearch(_:))
            item.searchField.delegate = self
            searchItem = item
            item.label = "Find"
            return item
        case .findCount:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = findCountLabel
            item.label = "Matches"
            return item
        case .vault:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            let writing = session.usesVault && session.vaultEnabled
            let symbol = NSImage(systemSymbolName: "link", accessibilityDescription: "Vault")
            if writing, let symbol {
                item.image = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
            } else {
                item.image = symbol
            }
            item.title = session.vaultName ?? "Vault"
            item.label = "Vault"
            item.menu = vaultMenu()
            item.isEnabled = session.usesVault
            return item
        case .toggleInspector, .inspectorTrackingSeparator:
            return nil
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

    private func highlightControl() -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .momentary
        control.segmentStyle = .separated
        control.setImage(NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Highlight"), forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Highlight color"), forSegment: 1)
        control.setWidth(32, forSegment: 0)
        control.setWidth(18, forSegment: 1)
        control.target = self
        control.action = #selector(highlightSegment(_:))
        return control
    }

    @objc private func highlightSegment(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            highlightLast(sender)
            return
        }
        let menu = NSMenu()
        for index in 1...6 {
            let item = NSMenuItem(title: HighlightCallout.name(for: index).capitalized, action: #selector(highlightFromMenu(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: item.title)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [ReaderColor.nsColor(index)]))
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove Highlight", action: #selector(removeHighlightUnderSelection(_:)), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        let origin = NSPoint(x: sender.width(forSegment: 0), y: sender.bounds.minY)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func highlightFromMenu(_ sender: NSMenuItem) { highlight(sender.tag) }

    @objc private func removeHighlightUnderSelection(_ sender: Any?) {
        if let id = session.lastAnnotationHit {
            session.removeAnnotationCompletely(id: id)
        }
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
    @objc func zoomIn(_ sender: Any?) { pdfController?.zoomIn(); epubController?.zoom(by: 1.15); session.showToast("\(Int((session.zoom * 100).rounded()))%") }
    @objc func zoomOut(_ sender: Any?) { pdfController?.zoomOut(); epubController?.zoom(by: 1 / 1.15); session.showToast("\(Int((session.zoom * 100).rounded()))%") }
    @objc func zoomToSelection(_ sender: Any?) { pdfController?.zoomToSelection() }
    @objc func rotateLeft(_ sender: Any?) { session.rotate(clockwise: false); pdfController?.refreshAnnotations() }
    @objc func rotateRight(_ sender: Any?) { session.rotate(clockwise: true); pdfController?.refreshAnnotations() }
    @objc func togglePanel(_ sender: Any?) { session.togglePanel(); applyChrome() }
    @objc func showNotesTab(_ sender: Any?) { session.show(tab: .notes); applyChrome() }
    @objc func showWordsTab(_ sender: Any?) { session.show(tab: .words); applyChrome() }
    @objc func showHighlightsTab(_ sender: Any?) { session.show(tab: .highlights); applyChrome() }
    @objc func showAskTab(_ sender: Any?) { session.show(tab: .askAI); applyChrome() }
    private func appearanceMenu() -> NSMenu {
        let menu = NSMenu()
        for theme in ["original", "paper", "quiet", "night"] {
            let item = NSMenuItem(title: theme.capitalized, action: #selector(chooseTheme(_:)), keyEquivalent: "")
            item.target = self
            item.state = session.package.state.epubTheme == theme ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for font in ["Original", "New York", "San Francisco", "Georgia", "Charter", "Iowan"] {
            let item = NSMenuItem(title: font, action: #selector(chooseFont(_:)), keyEquivalent: "")
            item.target = self
            item.state = session.package.state.epubFont == font ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, tag) in [("Tight", 0), ("Comfortable", 1), ("Loose", 2)] {
            let item = NSMenuItem(title: title, action: #selector(chooseLineSpacing(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = session.package.state.epubLine == tag ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, tag) in [("Narrow Margins", 0), ("Normal Margins", 1), ("Wide Margins", 2)] {
            let item = NSMenuItem(title: title, action: #selector(chooseMargin(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = session.package.state.epubMargin == tag ? .on : .off
            menu.addItem(item)
        }
        let justify = NSMenuItem(title: "Justify", action: #selector(chooseJustify(_:)), keyEquivalent: "")
        justify.target = self
        justify.state = session.package.state.epubJustify ? .on : .off
        menu.addItem(justify)
        return menu
    }

    @objc func chooseLineSpacing(_ sender: NSMenuItem) {
        session.package.state.epubLine = sender.tag
        session.saveViewQuietly()
        epubController?.applyLiveStyle()
    }

    @objc func chooseMargin(_ sender: NSMenuItem) {
        session.package.state.epubMargin = sender.tag
        session.saveViewQuietly()
        epubController?.applyLiveStyle()
    }

    @objc func chooseJustify(_ sender: NSMenuItem) {
        session.package.state.epubJustify.toggle()
        session.saveViewQuietly()
        epubController?.applyLiveStyle()
    }

    @objc func showAppearance(_ sender: Any?) {
        let menu = NSMenu()
        for theme in ["original", "paper", "quiet", "night"] {
            let item = NSMenuItem(title: theme.capitalized, action: #selector(chooseTheme(_:)), keyEquivalent: "")
            item.target = self
            item.state = session.package.state.epubTheme == theme ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for font in ["Original", "New York", "San Francisco", "Georgia", "Charter", "Iowan"] {
            let item = NSMenuItem(title: font, action: #selector(chooseFont(_:)), keyEquivalent: "")
            item.target = self
            item.state = session.package.state.epubFont == font ? .on : .off
            menu.addItem(item)
        }
        if let event = NSApp.currentEvent, let view = window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    @objc func chooseTheme(_ sender: NSMenuItem) {
        session.package.state.epubTheme = sender.title.lowercased()
        session.saveViewQuietly()
        epubController?.applyDisplayMode()
    }

    @objc func chooseFont(_ sender: NSMenuItem) {
        session.package.state.epubFont = sender.title
        session.saveViewQuietly()
        epubController?.applyDisplayMode()
    }

    @objc func showMarginNotes(_ sender: Any?) { session.toggleMarginNotes(); applyChrome() }
    @objc func exportNotes(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = session.bookURL.deletingPathExtension().lastPathComponent + " notes.md"
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            try? self.session.annotationMarkdown(self.session.annotations).write(to: url, atomically: true, encoding: .utf8)
        }
    }
    @objc override func selectAll(_ sender: Any?) {
        if let text = window?.firstResponder as? NSTextView, text.isEditable || text.isFieldEditor {
            text.selectAll(sender)
            return
        }
        let showingNotes = session.panelTab == .notes || session.panelTab == .highlights || session.sidebar == .highlightsAndNotes
        guard showingNotes else {
            (window?.firstResponder as? NSText)?.selectAll(sender)
            return
        }
        session.annotationSelection = Set(session.visibleAnnotations.map(\.id))
    }

    @objc func delete(_ sender: Any?) {
        if let text = window?.firstResponder as? NSTextView, text.isEditable {
            text.deleteToBeginningOfLine(sender)
            return
        }
        session.deleteSelectedAnnotations()
    }

    @objc func copyAllNotes(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.annotationMarkdown(session.annotations), forType: .string)
    }

    func showSelectionBar(relativeTo rect: NSRect, in host: NSView) {
        selectionBar.show(session: session, relativeTo: rect, of: host)
    }

    func dismissSelectionBar() { selectionBar.dismiss() }

    func presentNote(_ id: String) {
        let host = (pdfController?.view ?? epubController?.view) ?? window?.contentView
        guard let host else { return }
        let hostView = pdfController?.noteHostView ?? host
        let rect = pdfController?.noteRect(for: id) ?? NSRect(x: hostView.bounds.midX, y: hostView.bounds.midY, width: 1, height: 1)
        session.beginNoteEdit(id: id)
        notePopover.show(id: id, session: session, relativeTo: rect, of: hostView)
    }
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
    @objc func nextChapter(_ sender: Any?) { epubController?.nextPage() }
    @objc func previousChapter(_ sender: Any?) { epubController?.previousPage() }
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

    @objc func find(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    @objc func submitSearch(_ sender: Any?) {
        let query = searchItem?.searchField.stringValue ?? ""
        session.findQuery = query
        pdfController?.search(query)
        epubController?.search(query)
    }

    func showFindCount(_ index: Int, of total: Int) {
        let text = total > 0 ? "\(index) of \(total)" : ""
        if #available(macOS 26, *) {
            searchItem?.badge = text.isEmpty ? nil : NSItemBadge.text(text)
            findCountLabel.stringValue = ""
        } else {
            findCountLabel.stringValue = text
        }
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if let previous = session.sidebarBeforeSearch {
            session.setSidebar(previous)
            session.sidebarBeforeSearch = nil
        }
        if #available(macOS 26, *) {
            searchItem?.badge = nil
        }
        findCountLabel.stringValue = ""
    }
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
            if self.session.selection?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                self.session.addNote()
            } else if let hit = self.session.lastAnnotationHit {
                self.session.openAnnotation(hit)
            } else {
                NSSound.beep()
            }
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
        revealObsidian(id: nil)
    }

    func revealObsidian(id: String?) {
        guard session.usesVault, let vault = session.vaultName, let root = session.vaultRoot, let folder = session.bookFolder else { return }
        let item = id.flatMap { value in session.annotations.first { $0.id == value } }
        let chapter = ChapterFiles.number(in: item?.section ?? session.selection?.section ?? session.sectionTitle)
        let file = ObsidianLink.noteFile(
            vaultRoot: root,
            bookFolder: folder,
            notesFolder: session.vaultNotesFolder,
            chapter: chapter,
            bookTitle: session.bookURL.deletingPathExtension().lastPathComponent
        )
        if let url = URL(string: ObsidianLink.open(vault: vault, file: file, blockID: item?.id ?? id)) {
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
        case #selector(showMarginNotes(_:)): menuItem.state = session.showMarginNotes ? .on : .off
        case #selector(delete(_:)): return !session.annotationSelection.isEmpty
        case #selector(revealInObsidian(_:)), #selector(openVaultFolder(_:)), #selector(pauseVault(_:)):
            if menuItem.action == #selector(pauseVault(_:)) {
                menuItem.title = session.vaultEnabled ? "Pause Saving to Vault" : "Resume Saving to Vault"
            }
            return session.usesVault
        case #selector(linkVaultFolder(_:)):
            menuItem.title = session.usesVault ? "Unlink Vault Book Folder" : "Link to Vault Book Folder…"
            return true
        case #selector(nextChapter(_:)), #selector(previousChapter(_:)):
            return epubController != nil
        case #selector(bookmarkPage(_:)):
            menuItem.title = session.bookmarkExistsForCurrentPosition() ? "Remove Bookmark" : "Add Bookmark"
            return true
        case #selector(chooseTheme(_:)), #selector(chooseFont(_:)), #selector(chooseLineSpacing(_:)), #selector(chooseMargin(_:)), #selector(chooseJustify(_:)):
            return epubController != nil
        default: break
        }
        return true
    }

    @objc func openVaultFolder(_ sender: Any?) {
        guard let folder = session.bookFolder else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
    }

    @objc func pauseVault(_ sender: Any?) {
        session.vaultEnabled.toggle()
        session.onSaveVaultState?()
    }

    @objc func linkVaultFolder(_ sender: Any?) {
        if session.usesVault {
            var paths = UserDefaults.standard.stringArray(forKey: "reader.unlinkedVaults") ?? []
            if !paths.contains(session.bookURL.path) { paths.append(session.bookURL.path) }
            UserDefaults.standard.set(paths, forKey: "reader.unlinkedVaults")
            session.package.state.vaultBookFolder = nil
            storeVaultLink(nil)
            session.notice = "Unlinked. Reopen the book to use the sidecar."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let fs = LocalFileSystem()
            switch VaultFinder.resolve(bookPath: self.session.bookURL.path, linkedFolder: url.path, fs: fs) {
            case .vault(let location):
                self.session.package.state.vaultBookFolder = location.bookFolder
                self.storeVaultLink(location.bookFolder)
                self.mergeSidecarIntoVault(location)
                var paths = UserDefaults.standard.stringArray(forKey: "reader.unlinkedVaults") ?? []
                paths.removeAll { $0 == self.session.bookURL.path }
                UserDefaults.standard.set(paths, forKey: "reader.unlinkedVaults")
                self.session.notice = "Linked to \(location.bookFolder). Reopen the book to write there."
            case .missingLink, .none:
                self.session.notice = "That folder is not inside an Obsidian vault."
            }
        }
    }

    private func storeVaultLink(_ folder: String?) {
        let fs = LocalFileSystem()
        var index = LibraryIndex.load(from: AppPaths.indexFile, fs: fs)
        if let row = index.documents.firstIndex(where: { $0.bookPath == session.bookURL.path }) {
            index.documents[row].vaultBookFolder = folder
            try? index.save(to: AppPaths.indexFile, fs: fs)
        }
    }

    private func mergeSidecarIntoVault(_ location: VaultLocation) {
        let fs = LocalFileSystem()
        let directory = VaultPaths.notesDirectory(bookFolder: location.bookFolder, settings: VaultBookSettings.load(bookFolder: location.bookFolder, fs: fs))
        try? fs.createDirectory(directory)
        let name = ChapterFiles.notesFile(chapter: ChapterFiles.number(in: session.sectionTitle), bookTitle: session.bookURL.deletingPathExtension().lastPathComponent)
        let path = Paths.join(directory, name)
        let existing = (try? fs.readString(path)) ?? ""
        let merged = VaultAnnotationSync.mergeSidecarOnce(existing: existing, bookPath: session.bookURL.path, annotations: session.annotations)
        if merged != existing { try? fs.writeString(path, merged) }
    }

    private func vaultMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reveal Chapter", action: #selector(revealInObsidian(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open Vault Folder", action: #selector(openVaultFolder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: session.vaultEnabled ? "Pause Saving" : "Resume Saving", action: #selector(pauseVault(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Vault Settings", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
        for item in menu.items where item.action != #selector(AppDelegate.showSettings(_:)) {
            item.target = self
        }
        return menu
    }

    private func offerVaultSave() {
        guard session.usesVault, session.vaultLoose, !session.vaultEnabled else { return }
        let key = "reader.vaultOffer." + session.bookURL.path
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "This file is in your Obsidian vault"
        alert.informativeText = "Save notes into \(session.bookFolder ?? "the book folder")?"
        alert.addButton(withTitle: "Save to Vault")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            session.vaultEnabled = true
            session.onSaveVaultState?()
        }
    }

    private func showTipStrip() {
        guard !UserDefaults.standard.bool(forKey: "reader.didShowTips"), let content = window?.contentView else { return }
        UserDefaults.standard.set(true, forKey: "reader.didShowTips")
        let label = NSTextField(labelWithString: "Select text to highlight · ⇧⌘N adds a note · ⌥⌘4 shows them all")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.backgroundColor = .windowBackgroundColor
        label.drawsBackground = true
        label.alignment = .center
        label.frame = NSRect(x: 0, y: content.bounds.height - 28, width: content.bounds.width, height: 24)
        label.autoresizingMask = [.width, .minYMargin]
        content.addSubview(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { label.removeFromSuperview() }
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
    static let findCount = NSToolbarItem.Identifier("findCount")
    static let highlight = NSToolbarItem.Identifier("highlight")
    static let addNote = NSToolbarItem.Identifier("addNote")
    static let zoomIn = NSToolbarItem.Identifier("zoomIn")
    static let zoomOut = NSToolbarItem.Identifier("zoomOut")
    static let appearance = NSToolbarItem.Identifier("appearance")
    static let inspector = NSToolbarItem.Identifier("inspector")
    static let vault = NSToolbarItem.Identifier("vault")
}
