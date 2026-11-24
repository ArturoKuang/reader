import AppKit
import PDFKit
import ReaderCore
import SwiftUI
import WebKit

/// EPUB is rendered in WKWebView rather than Readium. The core package already parses
/// the ZIP, spine, and a CFI subset on any platform; WebKit only displays it. Reflow
/// zoom changes the font size. Two-page mode uses CSS columns, which is an approximation.
final class EPUBContainerViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    let session: ReaderSession
    private var webView: WKWebView?
    private let findBar = NSSearchField()
    private var findTop: NSLayoutConstraint?
    private var fontScale: Double = 1
    private var contactHost: NSHostingController<EPUBContactSheet>?
    private var spineLoaded = false
    private var acceptSpineReports = false
    private var chapterIndex = 0
    private var chapterScroll: Double = 0
    private var pendingChapterScroll: Double?
    private var pendingFlash: String?

    init(session: ReaderSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "reader")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
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
        chapterIndex = max(session.page - 1, 0)
        session.onAnnotationsChanged = { [weak self] in
            guard let self else { return }
            self.webView?.evaluateJavaScript("window.readerPaint && window.readerPaint(\(self.highlightScript()))")
        }
        loadSpine()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window == self.view.window, self.view.window?.firstResponder is WKWebView else { return event }
            let shift = event.modifierFlags.contains(.shift)
            if event.keyCode == 49 {
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
            if forward { self.nextPage() } else if self.session.page > 1 { self.previousPage() }
        }
    }

    func applyDisplayMode() {
        if webView?.url != nil, session.continuous {
            applyLiveStyle()
        } else {
            loadSpine()
        }
    }

    func setContactSheet(_ visible: Bool) {
        contactHost?.view.removeFromSuperview()
        contactHost = nil
        webView?.isHidden = visible
        guard visible else { return }
        let host = NSHostingController(rootView: EPUBContactSheet(session: session) { [weak self] index in
            self?.session.page = index + 1
            self?.session.setSidebar(.thumbnails)
            self?.loadSpine()
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

    func applyLiveStyle() {
        guard webView?.url != nil else { loadSpine(); return }
        let appearance = epubAppearance()
        let family = appearance.font.isEmpty ? "inherit" : appearance.font
        let script = """
        document.body.style.fontSize = '\(16 * fontScale)px';
        document.body.style.fontFamily = '\(family)';
        document.body.style.lineHeight = '\(appearance.line)';
        document.body.style.margin = '\(appearance.margin)px auto';
        document.body.style.background = '\(appearance.background)';
        document.body.style.color = '\(appearance.foreground)';
        document.body.style.textAlign = '\(appearance.align)';
        """
        webView?.evaluateJavaScript(script)
    }
    func nextPage() { showSpine(index: min(session.page, max(session.pageCount - 1, 0))) }
    func previousPage() { showSpine(index: max(session.page - 2, 0)) }
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
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.find('\(escaped)', false, \(!forward), true)")
    }

    func captureSelection() {
        captureSelection(completion: {})
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
                    if let index = self.integer(object["index"]), let epub = self.session.epub, epub.spine.indices.contains(index) {
                        self.applySpine(index, count: epub.spine.count)
                    }
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
        let index: Int
        if let cfi = position.cfi, let parsed = EPUBCFI(value: cfi), let spine = parsed.spineIndex {
            index = spine
        } else if let page = position.page {
            index = page - 1
        } else {
            return
        }
        pendingChapterScroll = position.scrollY
        showSpine(index: index)
        if let quote = position.quote, !quote.isEmpty { flash(quote) }
    }

    func consumePendingJump() {
        guard spineLoaded, let link = session.pendingReaderLink else { return }
        session.pendingReaderLink = nil
        let quote = session.highlights.first { $0.id == link.id }?.quote ?? session.notes.first { $0.id == link.id }?.quote ?? ""
        if !quote.isEmpty { pendingFlash = quote }
        if let location = link.location, let cfi = EPUBCFI(value: location), let index = cfi.spineIndex {
            showSpine(index: index)
        } else {
            scrollToCurrentSpine()
        }
        if let pendingFlash { flash(pendingFlash) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spineLoaded = true
        if let pending = session.pendingMarkReveal {
            session.pendingMarkReveal = nil
            pendingChapterScroll = pending.scrollY
            if let cfi = pending.cfi, let parsed = EPUBCFI(value: cfi), let spine = parsed.spineIndex {
                chapterIndex = spine
            } else if let page = pending.page {
                chapterIndex = max(page - 1, 0)
            }
        } else if session.pendingReaderLink != nil {
            consumePendingJump()
        } else if pendingChapterScroll == nil {
            scrollToCurrentSpine()
        }
        if pendingChapterScroll != nil, let epub = session.epub, epub.spine.indices.contains(chapterIndex) {
            scrollToSpine(epub.spine[chapterIndex].id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.acceptSpineReports = true
            self?.session.finishViewRestore()
        }
    }

    func currentPosition() -> ReadingPosition {
        let index = chapterIndex
        return ReadingPosition(
            page: index + 1,
            scrollY: chapterScroll,
            zoom: fontScale,
            cfi: EPUBCFI.make(spineIndex: index, start: 0, end: 0).value,
            section: session.sectionTitle,
            quote: session.selection?.text
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["kind"] as? String == "dismiss-bar" {
            (view.window?.windowController as? ReaderWindowController)?.dismissSelectionBar()
            return
        }
        if body["kind"] as? String == "note", let id = body["id"] as? String {
            session.lastAnnotationHit = id
            session.openAnnotation(id)
            return
        }
        if body["kind"] as? String == "scroll" {
            if let fraction = body["scrollY"] as? Double { chapterScroll = fraction }
            if let index = integer(body["index"]) { chapterIndex = index }
            return
        }
        if body["kind"] as? String == "spine" {
            guard acceptSpineReports, let index = integer(body["index"]), let epub = session.epub, epub.spine.indices.contains(index) else { return }
            applySpine(index, count: epub.spine.count)
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
        if let index = integer(body["index"]), let epub = session.epub, epub.spine.indices.contains(index) {
            applySpine(index, count: epub.spine.count)
        }
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

    private func showSpine(index: Int) {
        guard let epub = session.epub, epub.spine.indices.contains(index) else { return }
        applySpine(index, count: epub.spine.count)
        if session.continuous && spineLoaded {
            scrollToSpine(epub.spine[index].id)
        } else {
            loadSpine()
        }
    }

    private func scrollToCurrentSpine() {
        guard session.continuous, let epub = session.epub, !epub.spine.isEmpty else { return }
        let index = min(max(session.page - 1, 0), epub.spine.count - 1)
        applySpine(index, count: epub.spine.count)
        scrollToSpine(epub.spine[index].id)
    }

    private func scrollToSpine(_ id: String) {
        acceptSpineReports = false
        let escaped = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        if let fraction = pendingChapterScroll {
            pendingChapterScroll = nil
            let script = """
            (function() {
              const el = document.getElementById('spine-\(escaped)');
              const y = el ? el.offsetTop + el.offsetHeight * \(fraction) : document.body.scrollHeight * \(fraction);
              window.scrollTo(0, y);
            })();
            """
            webView?.evaluateJavaScript(script)
        } else {
            webView?.evaluateJavaScript("document.getElementById('spine-\(escaped)')?.scrollIntoView({block:'start'})")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.acceptSpineReports = true
        }
    }

    private func applySpine(_ index: Int, count: Int) {
        guard let epub = session.epub, epub.spine.indices.contains(index) else { return }
        let placements = SpineChapters.placements(spine: epub.spine, toc: epub.toc)
        let placement = placements[index]
        let title = placement.title.isEmpty ? epub.spine[index].title : placement.title
        chapterIndex = index
        session.updatePage(index + 1, count: count, section: title)
    }

    private func flash(_ quote: String) {
        let escaped = quote.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.webView?.evaluateJavaScript("window.readerFlash && window.readerFlash('\(escaped)')")
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

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func marginNoteScript() -> String {
        let items = session.annotations.filter(\.hasNote).map { item -> String in
            let quote = item.quote.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let body = item.body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let color = String(format: "#%02X%02X%02X", Int((HighlightPalette.rgb(item.color)?.r ?? 0) * 255), Int((HighlightPalette.rgb(item.color)?.g ?? 0) * 255), Int((HighlightPalette.rgb(item.color)?.b ?? 0) * 255))
            return "{\"id\":\"\(item.id)\",\"quote\":\"\(quote)\",\"body\":\"\(body)\",\"color\":\"\(color)\"}"
        }
        return "[\(items.joined(separator: ","))]"
    }

    private func highlightScript() -> String {
        let items = session.highlights.compactMap { highlight -> String? in
            let quote = highlight.quote.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            guard !quote.isEmpty else { return nil }
            return "{\"quote\":\"\(quote)\",\"color\":\(highlight.color)}"
        }
        return "[\(items.joined(separator: ","))]"
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
            if session.continuous { return true }
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
            let html = epub.xhtml(for: item.href) ?? "<p>Missing \(item.href)</p>"
            let heading = EPUBHeading.hasHeading(xhtml: html) ? "" : "<h2>\(item.title)</h2>"
            body += "<section id=\"spine-\(item.id)\" data-index=\"\(index)\" data-chapter=\"\(chapter.map(String.init) ?? "")\">\(heading)\(html)</section>"
        }
        let target = min(max(session.page - 1, 0), max(epub.spine.count - 1, 0))
        applySpine(target, count: epub.spine.count)
        let appearance = epubAppearance()
        let css = """
        body { font: \(16 * fontScale)px \(appearance.font.isEmpty ? "inherit" : appearance.font); line-height: \(appearance.line); margin: \(appearance.margin)px auto; max-width: \(session.twoPages ? 920 : 680)px; \(columns) background: \(appearance.background); color: \(appearance.foreground); text-align: \(appearance.align); }
        \(HighlightAppearance.css(dark: false))
        @media (prefers-color-scheme: dark) {
        \(HighlightAppearance.css(dark: true))
        }
        h2 { overflow-wrap: anywhere; }
        .reader-word { border-bottom: 1.5px dotted #666; }
        .reader-glyph { float: right; clear: right; border: 0; background: transparent; font-size: 14px; cursor: pointer; width: 16px; }
        .reader-concept { border-bottom: 1px solid #8e8e93; cursor: pointer; }
        .reader-badge { font: 10px -apple-system, sans-serif; margin-left: 3px; color: #8e8e93; cursor: pointer; }
        .reader-flash { background: #ffe08a; transition: background 1s; }
        """
        let marks = session.words.map(\.word).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: ",")
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>\(css)</style></head><body>
        \(body)
        <script>
        window.readerSelection = function() {
          const sel = document.getSelection();
          if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
          const text = sel.toString();
          const node = sel.anchorNode ? sel.anchorNode.textContent || "" : "";
          const start = Math.max(0, node.indexOf(text));
          const host = sel.anchorNode && (sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement);
          const section = host && host.closest ? host.closest("section[id^='spine-']") : null;
          const index = section ? Number(section.dataset.index || 0) : 0;
          const box = sel.getRangeAt(0).getBoundingClientRect();
          return { text, index, rect: { x: box.left, y: box.top, width: box.width, height: box.height }, prefix: node.slice(Math.max(0, start - 40), start), suffix: node.slice(start + text.length, start + text.length + 40), sentence: node.trim(), cfi: "epubcfi(/6/" + ((index + 1) * 2) + "!/4,/1:" + start + ",/1:" + (start + text.length) + ")" };
        };
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
        let reportScroll = () => {
          const sections = [...document.querySelectorAll("section[id^='spine-']")];
          const y = window.scrollY || 0;
          let index = 0;
          let scrollY = 0;
          for (const section of sections) {
            const top = section.offsetTop;
            const height = section.offsetHeight || 1;
            if (y + 8 >= top && y < top + height) {
              index = Number(section.dataset.index || 0);
              scrollY = Math.min(1, Math.max(0, (y - top) / height));
              break;
            }
          }
          if (window.webkit && window.webkit.messageHandlers.reader) {
            window.webkit.messageHandlers.reader.postMessage({kind: "scroll", index, scrollY});
          }
        };
        document.addEventListener("scroll", () => {
          if (window.webkit && window.webkit.messageHandlers.reader) window.webkit.messageHandlers.reader.postMessage({kind: "dismiss-bar"});
          reportScroll();
        }, true);
        document.addEventListener("mouseup", () => {
          const value = window.readerSelection();
          if (value && window.webkit && window.webkit.messageHandlers.reader) window.webkit.messageHandlers.reader.postMessage(value);
        });
        window.readerFlash = function(quote) {
          if (!quote) return;
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode;
            const at = (node.nodeValue || "").indexOf(quote);
            if (at < 0 || !node.parentNode) continue;
            const span = document.createElement("span");
            span.className = "reader-flash";
            span.textContent = quote;
            const text = node.nodeValue;
            node.parentNode.insertBefore(document.createTextNode(text.slice(0, at)), node);
            node.parentNode.insertBefore(span, node);
            node.parentNode.insertBefore(document.createTextNode(text.slice(at + quote.length)), node);
            node.parentNode.removeChild(node);
            span.scrollIntoView({block: "center"});
            setTimeout(() => { span.className = ""; }, 1200);
            break;
          }
        };
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
        window.readerPaint = function(marks) {
          (marks || []).forEach(mark => {
            if (!mark.quote) return;
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
              const node = walker.currentNode;
              if (!node.nodeValue || !node.parentNode) continue;
              if (node.parentNode.closest && node.parentNode.closest("[class*='reader-hl']")) continue;
              const at = node.nodeValue.indexOf(mark.quote);
              if (at < 0) continue;
              const span = document.createElement("span");
              span.className = "reader-hl-" + (mark.color || 1);
              span.textContent = mark.quote;
              const text = node.nodeValue;
              node.parentNode.insertBefore(document.createTextNode(text.slice(0, at)), node);
              node.parentNode.insertBefore(span, node);
              node.parentNode.insertBefore(document.createTextNode(text.slice(at + mark.quote.length)), node);
              node.parentNode.removeChild(node);
              break;
            }
          });
        };
        window.readerPaint(\(highlightScript()));
        window.readerMarginNotes = function(notes) {
          document.querySelectorAll(".reader-glyph").forEach(node => node.remove());
          (notes || []).forEach(note => {
            if (!note.quote) return;
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
              const node = walker.currentNode;
              if (!node.nodeValue || node.nodeValue.indexOf(note.quote) < 0 || !node.parentElement) continue;
              const section = node.parentElement.closest("section") || document.body;
              const mark = document.createElement("button");
              mark.className = "reader-glyph";
              mark.dataset.id = note.id;
              mark.textContent = "●";
              mark.style.color = note.color || "#888";
              mark.title = (note.body || "").split("\\n")[0];
              section.appendChild(mark);
              break;
            }
          });
        };
        window.readerMarginNotes(\(marginNoteScript()));
        const concepts = \(conceptScript());
        if (\(session.showConceptMarkers ? "true" : "false")) {
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
        }
        document.addEventListener("click", event => {
          const glyph = event.target.closest && event.target.closest(".reader-glyph");
          if (glyph && glyph.dataset.id && window.webkit) {
            window.webkit.messageHandlers.reader.postMessage({kind: "note", id: glyph.dataset.id});
            return;
          }
          const el = event.target.closest && event.target.closest(".reader-concept, .reader-badge");
          if (!el || !el.dataset.id || !window.webkit) return;
          window.webkit.messageHandlers.reader.postMessage({kind: "concept", id: el.dataset.id});
        });
        const words = [\(marks)];
        if (words.length) {
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const nodes = [];
          while (walker.nextNode()) nodes.push(walker.currentNode);
          nodes.forEach(node => {
            let text = node.nodeValue;
            words.forEach(word => {
              if (!word || !text.toLowerCase().includes(word.toLowerCase())) return;
              const span = document.createElement("span");
              span.className = "reader-word";
              const parent = node.parentNode;
              if (!parent || parent.classList.contains("reader-word")) return;
            });
          });
        }
        </script></body></html>
        """
        if let root = session.epubRoot {
            webView.loadHTMLString(html, baseURL: root)
        } else {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}
