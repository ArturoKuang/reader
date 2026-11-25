import AppKit
import PDFKit
import ReaderCore
import SwiftUI
import WebKit

/// EPUB and Markdown share this WKWebView. The core package parses both on any platform;
/// WebKit only displays them. Reflow zoom changes the font size. Two-page mode uses CSS
/// columns, which is an approximation.
final class WebDocumentContainerViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    let session: ReaderSession
    var webView: ReaderWebView?
    private let findBar = NSSearchField()
    private var findTop: NSLayoutConstraint?
    private var fontScale: Double = 1
    private var contactHost: NSHostingController<WebContactSheet>?
    var spineLoaded = false
    private var loadedLayout: PageLayout?
    private var watcher: MarkdownFileWatcher?
    private var keyMonitor: Any?
    private var acceptSpineReports = false
    private var pendingFlash: String?
    var onManualScrollDuringTTS: (() -> Void)?
    /// The open document changed under the player, so its plan no longer matches the page.
    var onTTSContentInvalidated: (() -> Void)?
    var ttsBottomInset: CGFloat = 0
    var ttsActiveHighlight: TTSWebHighlight?
    /// The spine item a single-page EPUB is loading so the voice can continue there.
    var ttsPendingSection: Int?
    var ttsViewport: (section: Int, offset: Int)?

    init(session: ReaderSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// Releases the file watcher, key monitor, and script handler when the window closes.
    func tearDown() {
        watcher?.stop()
        watcher = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
    }

    private var documentDirectory: String { session.bookURL.deletingLastPathComponent().path }

    override func loadView() {
        view = NSView()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "reader")
        let roots = [documentDirectory] + (session.vaultRoot.map { [$0] } ?? [])
        configuration.setURLSchemeHandler(LocalAssetSchemeHandler { roots }, forURLScheme: LocalAssetSchemeHandler.scheme)
        let webView = ReaderWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.onReadAloudFromHere = { [weak self] point in self?.readAloudFromContextMenu(at: point) }
        webView.session = session
        webView.translatesAutoresizingMaskIntoConstraints = false
        self.webView = webView
        view.addSubview(webView)
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.placeholderString = "Find"
        findBar.target = self
        findBar.action = #selector(submitFind)
        findBar.isHidden = true
        view.addSubview(findBar)
        let findConstraint = findBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: -40)
        findTop = findConstraint
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            findBar.widthAnchor.constraint(equalToConstant: 240),
            findConstraint,
        ])
        fontScale = session.zoom
        session.onAnnotationsChanged = { [weak self] in
            guard let self else { return }
            self.webView?.evaluateJavaScript("window.readerPaint && window.readerPaint(\(self.highlightScript())); window.readerMarginNotes && window.readerMarginNotes(\(self.marginNoteScript()));")
        }
        loadDocument()
        if session.isMarkdown {
            watcher = MarkdownFileWatcher(url: session.bookURL, initial: session.bookData) { [weak self] data in
                self?.reloadMarkdown(data)
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window == self.view.window, self.view.window?.firstResponder is WKWebView else { return event }
            let shift = event.modifierFlags.contains(.shift)
            if event.keyCode == 49 {
                // The window's monitor turns Space into play/pause while the player is open.
                if (self.view.window?.windowController as? ReaderWindowController)?.isTTSPresented == true { return event }
                self.scrollPage(forward: !shift)
                return nil
            }
            if event.keyCode == 124 { self.scrollPage(forward: true); return nil }
            if event.keyCode == 123 { self.scrollPage(forward: false); return nil }
            return event
        }
    }

    private func scrollPage(forward: Bool) {
        let direction = forward ? 1 : -1
        let check = forward ? "window.scrollY + window.innerHeight >= document.body.scrollHeight - 8" : "window.scrollY <= 8"
        webView?.evaluateJavaScript("window.scrollBy(0, window.innerHeight * 0.9 * \(direction)); \(check)") { [weak self] result, _ in
            guard let self, (result as? Bool) == true else { return }
            if self.session.isMarkdown { return }
            if forward { self.nextPage() } else if self.session.page > 1 { self.previousPage() }
        }
    }

    /// Which spine items the page holds. Markdown always holds the whole file.
    private enum PageLayout { case wholeDocument, single, twoPages }

    private var pageLayout: PageLayout {
        if session.isMarkdown || session.continuous { return .wholeDocument }
        return session.twoPages ? .twoPages : .single
    }

    /// Reloads only when the layout needs different content in the page.
    func applyDisplayMode() {
        if loadedLayout != pageLayout { loadDocument() }
        applyLiveStyle()
    }

    func setContactSheet(_ visible: Bool) {
        contactHost?.view.removeFromSuperview()
        contactHost = nil
        webView?.isHidden = visible
        guard visible else { return }
        let host = NSHostingController(rootView: WebContactSheet(session: session) { [weak self] index in
            self?.session.setSidebar(.thumbnails)
            self?.showSection(index: index)
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

    func actualSize() { fontScale = 1; session.rememberZoom(1, fit: .actual); applyLiveStyle() }
    func zoomToFit() { fontScale = 1.15; session.rememberZoom(fontScale, fit: .fitPage); applyLiveStyle() }
    func fitWidth() { fontScale = 1.15; session.rememberZoom(fontScale, fit: .fitWidth); applyLiveStyle() }
    func zoom(by factor: Double) {
        fontScale = min(max(fontScale * factor, 0.6), 2.4)
        session.rememberZoom(fontScale, fit: .custom)
        applyLiveStyle()
    }

    /// Restyles the page in place. A page still loading is styled by `didFinish`.
    func applyLiveStyle() {
        if spineLoaded { webView?.evaluateJavaScript(liveStyleScript()) }
        webView?.underPageBackgroundColor = pageBackgroundColor()
        let appearance = windowAppearance()
        if let window = view.window, window.appearance?.name != appearance?.name {
            window.appearance = appearance
        }
    }

    private func liveStyleScript() -> String {
        if session.isMarkdown {
            let options = markdownOptions()
            let variables = (try? JSONEncoder().encode(markdownVariables(options))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return "window.readerStyle && window.readerStyle(\(javaScriptString(options.theme)), \(variables), \(session.twoPages), \(javaScriptString(highlightCSS())));"
        }
        let appearance = epubAppearance()
        let family = appearance.font.isEmpty ? "inherit" : appearance.font
        return """
        document.body.style.fontSize = '\(16 * fontScale)px';
        document.body.style.fontFamily = '\(family)';
        document.body.style.lineHeight = '\(appearance.line)';
        document.body.style.margin = '\(appearance.margin)px auto';
        document.body.style.background = '\(appearance.background)';
        document.body.style.color = '\(appearance.foreground)';
        document.body.style.textAlign = '\(appearance.align)';
        window.readerTTSSetTheme && window.readerTTSSetTheme(\(javaScriptString(session.package.state.epubTheme)));
        """
    }

    private func pageBackgroundColor() -> NSColor {
        func rgb(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch session.package.state.epubTheme {
        case "paper": return rgb(0xF4ECD8)
        case "quiet": return rgb(0xECECEC)
        case "night": return rgb(0x1C1C1E)
        default: return .textBackgroundColor
        }
    }

    func nextPage() { showSection(index: min(session.page, max(session.pageCount - 1, 0))) }
    func previousPage() { showSection(index: max(session.page - 2, 0)) }
    func toggleFind() {
        findBar.isHidden = false
        findTop?.constant = 8
        if findBar.stringValue.isEmpty { findBar.stringValue = session.findQuery }
        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.findBar)
            self.findBar.currentEditor()?.selectAll(nil)
        }
    }
    func search(_ query: String) {
        findBar.stringValue = query
        session.findQuery = query
        find(forward: true)
    }

    @objc private func submitFind() { find(forward: true) }
    func find(forward: Bool) {
        let query = findBar.stringValue.isEmpty ? session.findQuery : findBar.stringValue
        session.findQuery = query
        webView?.evaluateJavaScript("window.find(\(javaScriptString(query)), false, \(!forward), true)")
    }

    func hasActiveSelection(completion: @escaping (Bool) -> Void) {
        guard let webView else { return completion(false) }
        webView.evaluateJavaScript("String(document.getSelection()).trim().length > 0") { result, _ in
            completion(result as? Bool ?? false)
        }
    }

    /// Reads the DOM selection and only then runs `completion`, on the main queue.
    func captureSelection(completion: @escaping () -> Void) {
        guard let webView else {
            completion()
            return
        }
        webView.evaluateJavaScript("window.readerSelection && window.readerSelection()") { [weak self] result, _ in
            DispatchQueue.main.async {
                if let self, let object = result as? [String: Any], let text = object["text"] as? String, !text.isEmpty {
                    if let index = self.integer(object["index"]) { self.applySection(index) }
                    self.session.selection = SelectionContext(
                        text: text,
                        cfi: object["cfi"] as? String,
                        section: self.session.sectionTitle,
                        prefix: object["prefix"] as? String ?? "",
                        suffix: object["suffix"] as? String ?? "",
                        sentence: object["sentence"] as? String ?? text,
                        rects: []
                    )
                }
                completion()
            }
        }
    }

    func reveal(_ position: ReadingPosition) {
        if session.isMarkdown {
            if let anchor = position.cfi.flatMap({ MarkdownAnchor(value: $0) }) {
                applySection(anchor.sectionIndex)
                scrollToAnchor(anchor.anchorID)
            } else if let page = position.page {
                showSection(index: page - 1)
            }
        } else if let cfi = position.cfi, let parsed = EPUBCFI(value: cfi), let index = parsed.spineIndex {
            showSection(index: index)
        } else if let page = position.page {
            showSection(index: page - 1)
        }
        if let quote = position.quote, !quote.isEmpty { flash(quote) }
    }

    func consumePendingJump() {
        guard spineLoaded else { return }
        if let anchor = session.pendingAnchor {
            session.pendingAnchor = nil
            scrollToAnchor(anchor)
        }
        guard let link = session.pendingReaderLink else { return }
        session.pendingReaderLink = nil
        let quote = session.highlights.first { $0.id == link.id }?.quote ?? session.notes.first { $0.id == link.id }?.quote ?? ""
        if let location = link.location, let anchor = MarkdownAnchor(value: location) {
            reveal(ReadingPosition(cfi: anchor.rawValue))
        } else if let location = link.location, let cfi = EPUBCFI(value: location), let index = cfi.spineIndex {
            showSection(index: index)
        } else {
            scrollToCurrentSection()
        }
        if !quote.isEmpty { flash(quote) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spineLoaded = true
        // Picks up anything chosen while the page was loading, before scrolling measures it.
        applyLiveStyle()
        resumeTTSAfterLoad()
        if session.pendingReaderLink == nil, session.pendingAnchor == nil { scrollToCurrentSection() }
        consumePendingJump()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.acceptSpineReports = true
            self?.session.finishViewRestore()
        }
    }

    /// The web view only ever shows the loaded document; every link leaves through here.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        // loadHTMLString arrives as `.other`; same-document fragments scroll in place.
        let sameDocument = url.fragment != nil && url.path == webView.url?.path && url.scheme == webView.url?.scheme
        if sameDocument || (navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame != false) {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        guard navigationAction.navigationType == .linkActivated else { return }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto", "obsidian", "reader":
            NSWorkspace.shared.open(url)
        case "reader-wikilink":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            openWikiLink(target: items.first { $0.name == "target" }?.value ?? "", heading: items.first { $0.name == "heading" }?.value)
        case LocalAssetSchemeHandler.scheme:
            // A relative Markdown link, such as [next](chapter-2.md#setup).
            guard BookKind.from(path: url.path) != nil else { return session.showToast("Can't open \(url.lastPathComponent)") }
            openWikiLink(target: relativeTarget(url.path), heading: url.fragment)
        case "file":
            // An EPUB link to another chapter.
            if let index = session.epub?.spine.firstIndex(where: { url.path.hasSuffix("/" + $0.href) }) { showSection(index: index) }
        default:
            break
        }
    }

    private func relativeTarget(_ path: String) -> String {
        path.hasPrefix(documentDirectory + "/") ? String(path.dropFirst(documentDirectory.count + 1)) : path
    }

    private func openWikiLink(target: String, heading: String?) {
        let resolution = MarkdownWikiLinkResolver.resolve(target: target, heading: heading, currentFilePath: session.bookURL.path, vaultRoot: session.vaultRoot, fs: LocalFileSystem())
        switch resolution {
        case .localHeading(let anchor):
            scrollToAnchor(anchor)
        case .file(let path, let anchor):
            NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { [weak self] document, _, error in
                guard let document = document as? ReaderDocument else {
                    self?.session.showToast(error?.localizedDescription ?? "Couldn't open \(target)")
                    return
                }
                guard let anchor else { return }
                document.session?.pendingAnchor = anchor
                (document.windowControllers.first as? ReaderWindowController)?.consumePendingJump()
            }
        case .notFound(let target):
            session.showToast("Couldn't find \(target)")
        }
    }

    private func scrollToAnchor(_ anchor: String) {
        call("window.readerScrollToAnchor(anchor)", ["anchor": anchor])
    }

    private func call(_ body: String, _ arguments: [String: Any]) {
        webView?.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    func currentPosition() -> ReadingPosition {
        ReadingPosition(
            zoom: fontScale,
            cfi: session.currentLocation(),
            section: session.sectionTitle,
            quote: session.selection?.text
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["kind"] as? String == "tts-manual-scroll" {
            onManualScrollDuringTTS?()
            return
        }
        if body["kind"] as? String == "dismiss-bar" {
            (view.window?.windowController as? ReaderWindowController)?.dismissSelectionBar()
            return
        }
        if body["kind"] as? String == "copy", let code = body["code"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            session.showToast("Copied")
            return
        }
        if let kind = body["kind"] as? String, kind == "note" || kind == "open-highlight", let id = body["id"] as? String {
            session.lastAnnotationHit = id
            session.openAnnotation(id)
            return
        }
        if body["kind"] as? String == "context-highlight" {
            webView?.contextHighlightID = body["id"] as? String
            return
        }
        if body["kind"] as? String == "spine" {
            guard acceptSpineReports, let index = integer(body["index"]) else { return }
            applySection(index)
            return
        }
        if body["kind"] as? String == "concept", let id = body["id"] as? String, let concept = session.concepts.first(where: { $0.id == id }) {
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
            return
        }
        guard let text = body["text"] as? String else { return }
        if let index = integer(body["index"]) { applySection(index) }
        session.selection = SelectionContext(
            text: text,
            cfi: body["cfi"] as? String,
            section: session.sectionTitle,
            prefix: body["prefix"] as? String ?? "",
            suffix: body["suffix"] as? String ?? "",
            sentence: body["sentence"] as? String ?? text,
            rects: []
        )
        if session.settings.showSelectionBar, let webView, let rect = cssSelectionRect(body["rect"], in: webView) {
            (view.window?.windowController as? ReaderWindowController)?.showSelectionBar(relativeTo: rect, in: webView)
        }
    }

    func showSection(index: Int) {
        guard index >= 0, index < session.pageCount else { return }
        applySection(index)
        if let markdown = session.markdown {
            guard markdown.sections.indices.contains(index) else { return }
            scrollToAnchor(markdown.sections[index].anchorID)
        } else if let epub = session.epub, epub.spine.indices.contains(index) {
            if session.continuous && spineLoaded {
                scrollToSpine(epub.spine[index].id)
            } else {
                loadDocument()
            }
        }
    }

    private func scrollToCurrentSection() {
        guard session.isMarkdown || session.continuous else { return }
        let index = min(max(session.page - 1, 0), max(session.pageCount - 1, 0))
        // The top of a Markdown file includes its properties, so section one stays put.
        if session.isMarkdown && index == 0 { return applySection(0) }
        showSection(index: index)
    }

    private func scrollToSpine(_ id: String) {
        acceptSpineReports = false
        let escaped = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("document.getElementById('spine-\(escaped)')?.scrollIntoView({block:'start'})")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.acceptSpineReports = true
        }
    }

    private func applySection(_ index: Int) {
        if let markdown = session.markdown {
            guard markdown.sections.indices.contains(index) else { return }
            session.updatePage(index + 1, count: markdown.sections.count, section: markdown.sections[index].title)
        } else if let epub = session.epub, epub.spine.indices.contains(index) {
            let placement = SpineChapters.placements(spine: epub.spine, toc: epub.toc)[index]
            let title = placement.title.isEmpty ? epub.spine[index].title : placement.title
            session.updatePage(index + 1, count: epub.spine.count, section: title)
        }
    }

    private func flash(_ quote: String) {
        let literal = javaScriptString(quote)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.webView?.evaluateJavaScript("window.readerFlash && window.readerFlash(\(literal))")
        }
    }

    private func cssSelectionRect(_ value: Any?, in webView: WKWebView) -> NSRect? {
        guard let rect = value as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? {
            if let value = rect[key] as? NSNumber { return CGFloat(truncating: value) }
            return nil
        }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height"), width > 1, height > 1 else { return nil }
        if webView.isFlipped {
            return NSRect(x: x, y: y, width: width, height: height)
        }
        return NSRect(x: x, y: webView.bounds.height - y - height, width: width, height: height)
    }

    var noteHostView: NSView { webView ?? view }

    /// Where the highlight for `id` is, in the web view's own coordinates. Scrolls it into view when
    /// it is off screen. Nil when the page does not show it.
    func noteRect(for id: String, completion: @escaping (NSRect?) -> Void) {
        guard let webView, spineLoaded else { return completion(nil) }
        let key = session.annotation(matching: id)?.id ?? id
        webView.callAsyncJavaScript(
            "return window.readerHighlightRect ? window.readerHighlightRect(id) : null;",
            arguments: ["id": key], in: nil, in: .page
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, let webView = self.webView, case .success(let value) = result else { return completion(nil) }
                completion(self.cssSelectionRect(value, in: webView))
            }
        }
    }

    func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func marginNoteScript() -> String {
        json(session.annotations.filter(\.hasNote).map { item -> [String: Any] in
            let rgb = HighlightPalette.rgb(item.color)
            let color = String(format: "#%02X%02X%02X", Int((rgb?.r ?? 0) * 255), Int((rgb?.g ?? 0) * 255), Int((rgb?.b ?? 0) * 255))
            return ["id": item.id, "quote": item.quote, "body": item.body, "color": color]
        })
    }

    /// Each highlight with the text around it, so a quote that repeats paints the right occurrence.
    private func highlightScript() -> String {
        let bodies = Dictionary(session.notes.map { ($0.id, $0.body) }, uniquingKeysWith: { first, _ in first })
        return json(session.highlights.filter { !$0.quote.isEmpty }.map { highlight -> [String: Any] in
            [
                "id": highlight.id, "quote": highlight.quote, "color": highlight.color,
                "prefix": highlight.prefix, "suffix": highlight.suffix, "hasNote": highlight.noteID != nil,
                "body": highlight.noteID.flatMap { bodies[$0] } ?? "",
            ]
        })
    }

    /// A JSON array literal; JSONSerialization escapes newlines and `</script>` slashes.
    private func json(_ value: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func epubAppearance() -> (font: String, line: String, margin: Int, background: String, foreground: String, align: String) {
        let state = session.package.state
        let font: String
        switch state.epubFont {
        case "New York": font = "\"New York\", serif"
        case "San Francisco": font = "-apple-system, sans-serif"
        case "Georgia": font = "Georgia, serif"
        case "Charter": font = "Charter, serif"
        case "Iowan": font = "\"Iowan Old Style\", serif"
        default: font = ""
        }
        let lines = ["1.4", "1.6", "1.9"]
        let margins = [24, 48, 80]
        let line = lines[min(max(state.epubLine, 0), 2)]
        let margin = margins[min(max(state.epubMargin, 0), 2)]
        switch state.epubTheme {
        case "paper": return (font, line, margin, "#f4ecd8", "#2b2118", state.epubJustify ? "justify" : "start")
        case "quiet": return (font, line, margin, "#ececec", "#1c1c1e", state.epubJustify ? "justify" : "start")
        case "night": return (font, line, margin, "#1c1c1e", "#f2f2f7", state.epubJustify ? "justify" : "start")
        default: return (font, line, margin, "transparent", "inherit", state.epubJustify ? "justify" : "start")
        }
    }

    private func conceptScript() -> String {
        let chapter = ChapterFiles.number(in: session.sectionTitle)
        let visible = session.concepts.filter { concept in
            guard session.showConceptMarkers else { return false }
            if session.continuous || session.isMarkdown { return true }
            return concept.chapter == nil || concept.chapter == chapter
        }
        let items = visible.map { concept -> String in
            let terms = concept.findTerms.map { term in
                let escaped = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }.joined(separator: ",")
            let color: String
            switch MasteryFile.badge(session.mastery[concept.id]) {
            case .notStarted: color = "#8e8e93"
            case .learning: color = "#0a84ff"
            case .known: color = "#30d158"
            case .due: color = "#ff9f0a"
            }
            let chapterField = concept.chapter.map(String.init) ?? ""
            return "{\"id\":\"\(concept.id)\",\"color\":\"\(color)\",\"chapter\":\"\(chapterField)\",\"terms\":[\(terms)]}"
        }
        return "[\(items.joined(separator: ","))]"
    }

    private func loadDocument() {
        loadedLayout = pageLayout
        if session.isMarkdown { loadMarkdown() } else { loadSpine() }
    }

    private func markdownOptions() -> MarkdownRenderOptions {
        let state = session.package.state
        return MarkdownRenderOptions(
            documentDirectory: documentDirectory, vaultRoot: session.vaultRoot, theme: state.epubTheme, fontFamily: state.epubFont,
            fontScale: fontScale, lineHeight: ["1.4", "1.6", "1.9"][min(max(state.epubLine, 0), 2)],
            marginPx: [24, 48, 80][min(max(state.epubMargin, 0), 2)], justify: state.epubJustify, twoPages: session.twoPages
        )
    }

    /// The same custom properties `renderDocumentHTML` puts on the body.
    private func markdownVariables(_ options: MarkdownRenderOptions) -> [String: String] {
        let family = epubAppearance().font
        return [
            "--font-family": family.isEmpty ? "-apple-system, sans-serif" : family,
            "--font-scale": String(options.fontScale), "--line-height": options.lineHeight,
            "--page-margin": "\(options.marginPx)px", "--text-align": options.justify ? "justify" : "start",
        ]
    }

    private func highlightCSS() -> String {
        switch session.package.state.epubTheme {
        case "night": return HighlightAppearance.css(dark: true)
        case "paper", "quiet": return HighlightAppearance.css(dark: false)
        default: return HighlightAppearance.css(dark: false) + "\n@media (prefers-color-scheme: dark) {\n" + HighlightAppearance.css(dark: true) + "\n}"
        }
    }

    private func windowAppearance() -> NSAppearance? {
        switch session.package.state.epubTheme {
        case "night": return NSAppearance(named: .darkAqua)
        case "paper", "quiet": return NSAppearance(named: .aqua)
        default: return nil
        }
    }

    private func loadMarkdown() {
        guard let model = session.markdown, let webView else { return }
        acceptSpineReports = false
        let script = readerScript() + """

        window.readerStyle(null, null, \(session.twoPages), \(javaScriptString(highlightCSS())));
        """
        let html = MarkdownHTMLRenderer.renderDocumentHTML(model, options: markdownOptions(), injectedScript: script, fs: LocalFileSystem())
        webView.loadHTMLString(html, baseURL: LocalAssetSchemeHandler.url(for: session.bookURL))
    }

    /// Swaps only the article, so the page neither flashes nor loses its scroll position.
    private func reloadMarkdown(_ data: Data) {
        session.reloadMarkdown(data: data)
        (view.window?.windowController?.document as? ReaderDocument)?.bookDidChange(data)
        // The spoken plan indexes the old text, so it cannot survive the swap.
        if ttsBottomInset > 0 { onTTSContentInvalidated?() }
        guard spineLoaded, let model = session.markdown else { return loadMarkdown() }
        let article = MarkdownHTMLRenderer.renderArticleHTML(model, options: markdownOptions(), fs: LocalFileSystem())
        call("window.readerReplaceArticle(article, JSON.parse(highlights), JSON.parse(notes), JSON.parse(concepts))", [
            "article": article, "highlights": highlightScript(), "notes": marginNoteScript(), "concepts": conceptScript(),
        ])
    }

    func javaScriptString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private func loadSpine() {
        guard let epub = session.epub, let webView else { return }
        let items: [EPUBSpineItem]
        if session.continuous {
            items = epub.spine
        } else if session.twoPages {
            let start = max(session.page - 1, 0)
            items = Array(epub.spine.dropFirst(start).prefix(2))
        } else {
            let index = min(max(session.page - 1, 0), max(epub.spine.count - 1, 0))
            items = [epub.spine[index]]
            session.sectionTitle = epub.spine[index].title
            session.updatePage(index + 1, count: epub.spine.count, section: epub.spine[index].title)
        }
        let columns = session.twoPages && !session.continuous ? "column-count: 2; column-gap: 32px; height: 100vh;" : ""
        acceptSpineReports = false
        let placements = SpineChapters.placements(spine: epub.spine, toc: epub.toc)
        var body = ""
        for item in items {
            let index = epub.spine.firstIndex(where: { $0.id == item.id }) ?? 0
            let chapter = placements.indices.contains(index) ? placements[index].chapter : nil
            body += "<section id=\"spine-\(item.id)\" data-index=\"\(index)\" data-chapter=\"\(chapter.map(String.init) ?? "")\">\(spineSectionHTML(item, in: epub))</section>"
        }
        let target = min(max(session.page - 1, 0), max(epub.spine.count - 1, 0))
        applySection(target)
        let appearance = epubAppearance()
        let css = """
        body { font: \(16 * fontScale)px \(appearance.font.isEmpty ? "inherit" : appearance.font); line-height: \(appearance.line); margin: \(appearance.margin)px auto; max-width: \(session.twoPages ? 920 : 680)px; \(columns) background: \(appearance.background); color: \(appearance.foreground); text-align: \(appearance.align); }
        \(HighlightAppearance.css(dark: false))
        @media (prefers-color-scheme: dark) {
        \(HighlightAppearance.css(dark: true))
        }
        h2 { overflow-wrap: anywhere; }
        .reader-word { border-bottom: 1.5px dotted #666; }
        \(WebAnnotationScript.css)
        .reader-concept { border-bottom: 1px solid #8e8e93; cursor: pointer; }
        .reader-badge { font: 10px -apple-system, sans-serif; margin-left: 3px; color: #8e8e93; cursor: pointer; }
        .reader-flash { background: #ffe08a; transition: background 1s; }
        """
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>\(css)</style></head><body>
        \(body)
        <script>\(readerScript())</script></body></html>
        """
        if let root = session.epubRoot {
            webView.loadHTMLString(html, baseURL: root)
        } else {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// What goes inside a spine item's `<section>`: a heading when the chapter has none, then its body.
    func spineSectionHTML(_ item: EPUBSpineItem, in epub: EPUBBook) -> String {
        let html = epub.xhtml(for: item.href) ?? "<p>Missing \(item.href)</p>"
        let heading = EPUBHeading.hasHeading(xhtml: html) ? "" : "<h2>\(item.title)</h2>"
        return heading + html
    }

    /// Selection, highlights, notes, concepts, and scroll reporting for both document kinds.
    private func readerScript() -> String {
        return WebTTSScript.source + "\n" + WebAnnotationScript.source + "\n" + """
        const sections = [...document.querySelectorAll("section[id^='spine-']")];
        if (sections.length) {
          const observer = new IntersectionObserver(entries => {
            const visible = entries.filter(entry => entry.isIntersecting).sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
            if (!visible) return;
            const index = Number(visible.target.dataset.index || 0);
            if (window.webkit && window.webkit.messageHandlers.reader) window.webkit.messageHandlers.reader.postMessage({kind: "spine", index});
          }, { root: null, threshold: [0.2, 0.5] });
          sections.forEach(section => observer.observe(section));
        }
        let sectionTick = false;
        window.addEventListener("scroll", () => {
          if (sectionTick) return;
          sectionTick = true;
          requestAnimationFrame(() => {
            sectionTick = false;
            const all = [...document.querySelectorAll("section[data-tts-section]")];
            if (!all.length) return;
            const passed = all.filter(section => section.getBoundingClientRect().top <= window.innerHeight * 0.3);
            const current = passed.length ? passed[passed.length - 1] : all[0];
            window.webkit.messageHandlers.reader.postMessage({kind: "spine", index: Number(current.dataset.ttsSection)});
          });
        });
        window.readerScrollToAnchor = function(anchor) {
          const target = document.getElementById(anchor) || document.querySelector('section[data-anchor="' + CSS.escape(anchor) + '"]');
          if (!target) return;
          for (let el = target; el; el = el.parentElement) if (el.tagName === "DETAILS") el.open = true;
          target.scrollIntoView({behavior: "smooth", block: "start"});
        };
        window.readerStyle = function(theme, variables, columns, highlightCSS) {
          if (theme) { document.body.dataset.theme = theme; if (window.readerTTSSetTheme) window.readerTTSSetTheme(theme); }
          Object.entries(variables || {}).forEach(([key, value]) => document.body.style.setProperty(key, value));
          const article = document.getElementById("reader-md-article");
          if (article) {
            article.style.columnCount = columns ? "2" : "auto";
            document.body.style.maxWidth = columns ? "1400px" : "720px";
          }
          let style = document.getElementById("reader-app-style");
          if (!style) {
            style = document.createElement("style");
            style.id = "reader-app-style";
            document.head.appendChild(style);
          }
          const nextCSS = highlightCSS + " " + \(javaScriptString(WebAnnotationScript.css)) + " .reader-concept { border-bottom: 1px solid #8e8e93; cursor: pointer; } .reader-badge { font: 10px -apple-system, sans-serif; margin-left: 3px; color: #8e8e93; cursor: pointer; } .reader-flash { background: #ffe08a; transition: background 1s; } pre { position: relative; } .reader-copy { position: absolute; right: 8px; bottom: 8px; font: 11px -apple-system, sans-serif; opacity: 0; cursor: pointer; } pre:hover .reader-copy, .reader-copy:focus { opacity: 1; }";
          // Reassigning identical CSS would re-parse the sheet and restyle the whole page.
          if (style.textContent !== nextCSS) style.textContent = nextCSS;
        };
        window.readerAddCopyButtons = function() {
          document.querySelectorAll("#reader-md-article pre").forEach(pre => {
            const button = document.createElement("button");
            button.className = "reader-copy";
            button.dataset.ttsExclude = "true";
            button.textContent = "Copy";
            button.addEventListener("click", () => window.webkit.messageHandlers.reader.postMessage({kind: "copy", code: pre.querySelector("code").textContent}));
            pre.appendChild(button);
          });
        };
        window.readerAddCopyButtons();
        window.readerReplaceArticle = function(html, highlights, notes, concepts) {
          const x = window.scrollX, y = window.scrollY;
          if (window.readerTTSReset) window.readerTTSReset();
          const article = document.getElementById("reader-md-article");
          const open = [...article.querySelectorAll("details")].map(el => el.open);
          article.style.minHeight = article.offsetHeight + "px";
          article.innerHTML = html;
          const details = article.querySelectorAll("details");
          if (details.length === open.length) details.forEach((el, i) => { el.open = open[i]; });
          article.style.minHeight = "";
          window.readerAddCopyButtons();
          window.readerPaint(highlights);
          window.readerMarginNotes(notes);
          window.readerPaintConcepts(concepts);
          window.scrollTo(x, y);
        };
        document.addEventListener("scroll", () => {
          if (window.webkit && window.webkit.messageHandlers.reader) window.webkit.messageHandlers.reader.postMessage({kind: "dismiss-bar"});
        }, true);
        document.addEventListener("mouseup", () => {
          const value = window.readerSelection();
          if (value && window.webkit && window.webkit.messageHandlers.reader) window.webkit.messageHandlers.reader.postMessage(value);
        });
        function tokenAt(text, at, length) {
          const word = /[0-9A-Za-z'’]/;
          if (at > 0 && word.test(text[at - 1])) return false;
          if (at + length < text.length && word.test(text[at + length])) return false;
          return true;
        }
        function findTerm(text, term) {
          const lower = text.toLowerCase();
          const needle = term.toLowerCase();
          let from = 0;
          while (from < lower.length) {
            const at = lower.indexOf(needle, from);
            if (at < 0) return -1;
            if (tokenAt(text, at, needle.length)) return at;
            from = at + needle.length;
          }
          return -1;
        }
        window.readerPaint(\(highlightScript()));
        window.readerMarginNotes(\(marginNoteScript()));
        window.readerPaintConcepts = function(concepts) {
          concepts.forEach(concept => {
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            const nodes = [];
            while (walker.nextNode()) nodes.push(walker.currentNode);
            nodes.forEach(node => {
              if (!node.nodeValue || !node.parentNode || node.parentNode.closest && node.parentNode.closest(".reader-concept")) return;
              const section = node.parentElement && node.parentElement.closest && node.parentElement.closest("section[data-chapter]");
              const sectionChapter = section ? (section.dataset.chapter || "") : "";
              if (concept.chapter && sectionChapter !== concept.chapter) return;
              for (const term of concept.terms) {
                const at = findTerm(node.nodeValue, term);
                if (at < 0) continue;
                const span = document.createElement("span");
                span.className = "reader-concept";
                span.dataset.id = concept.id;
                span.style.borderBottomColor = concept.color;
                span.textContent = node.nodeValue.slice(at, at + term.length);
                const badge = document.createElement("sup");
                badge.className = "reader-badge";
                badge.dataset.id = concept.id;
                badge.style.color = concept.color;
                badge.textContent = concept.id;
                const text = node.nodeValue;
                node.parentNode.insertBefore(document.createTextNode(text.slice(0, at)), node);
                node.parentNode.insertBefore(span, node);
                node.parentNode.insertBefore(badge, node);
                node.parentNode.insertBefore(document.createTextNode(text.slice(at + term.length)), node);
                node.parentNode.removeChild(node);
                break;
              }
            });
          });
          if (window.readerTTSInvalidate) window.readerTTSInvalidate();
        };
        window.readerPaintConcepts(\(conceptScript()));
        window.readerTTSSetTheme(\(javaScriptString(session.package.state.epubTheme)));
        document.addEventListener("contextmenu", event => {
          const painted = event.target.closest && event.target.closest("span[data-annotation-id]");
          if (window.webkit) window.webkit.messageHandlers.reader.postMessage({kind: "context-highlight", id: painted ? painted.dataset.annotationId : null});
        }, true);
        document.addEventListener("click", event => {
          const glyph = event.target.closest && event.target.closest(".reader-glyph");
          if (glyph && glyph.dataset.id && window.webkit) {
            window.webkit.messageHandlers.reader.postMessage({kind: "note", id: glyph.dataset.id});
            return;
          }
          // A click on a highlight opens its note; a drag that ends on one is a selection.
          const painted = event.target.closest && event.target.closest("span[data-annotation-id]");
          const selection = window.getSelection && window.getSelection();
          if (painted && painted.dataset.annotationId && (!selection || selection.isCollapsed) && window.webkit) {
            window.webkit.messageHandlers.reader.postMessage({kind: "open-highlight", id: painted.dataset.annotationId});
            return;
          }
          const el = event.target.closest && event.target.closest(".reader-concept, .reader-badge");
          if (!el || !el.dataset.id || !window.webkit) return;
          window.webkit.messageHandlers.reader.postMessage({kind: "concept", id: el.dataset.id});
        });
        """
    }
}
