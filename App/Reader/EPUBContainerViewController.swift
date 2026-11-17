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
        let findConstraint = findBar.topAnchor.constraint(equalTo: view.topAnchor, constant: -40)
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
        loadSpine()
    }

    func applyDisplayMode() { loadSpine() }

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

    func actualSize() { fontScale = 1; session.rememberZoom(1, fit: .actual); loadSpine() }
    func zoomToFit() { fontScale = 1.15; session.rememberZoom(fontScale, fit: .fitPage); loadSpine() }
    func fitWidth() { fontScale = 1.15; session.rememberZoom(fontScale, fit: .fitWidth); loadSpine() }
    func zoom(by factor: Double) {
        fontScale = min(max(fontScale * factor, 0.6), 2.4)
        session.rememberZoom(fontScale, fit: .custom)
        loadSpine()
    }
    func nextPage() { showSpine(index: min(session.page, max(session.pageCount - 1, 0))) }
    func previousPage() { showSpine(index: max(session.page - 2, 0)) }
    func toggleFind() {
        findBar.isHidden.toggle()
        findTop?.constant = findBar.isHidden ? -40 : 8
        if !findBar.isHidden { view.window?.makeFirstResponder(findBar) }
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
        if let cfi = position.cfi, let parsed = EPUBCFI(value: cfi), let index = parsed.spineIndex {
            showSpine(index: index)
        } else if let page = position.page {
            showSpine(index: page - 1)
        }
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
        if session.pendingReaderLink != nil {
            consumePendingJump()
        } else {
            scrollToCurrentSpine()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.acceptSpineReports = true
            self?.session.finishViewRestore()
        }
    }

    func currentPosition() -> ReadingPosition {
        let index = min(max(session.page - 1, 0), max((session.epub?.spine.count ?? 1) - 1, 0))
        return ReadingPosition(
            zoom: fontScale,
            cfi: EPUBCFI.make(spineIndex: index, start: 0, end: 0).value,
            section: session.sectionTitle,
            quote: session.selection?.text
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
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
        webView?.evaluateJavaScript("document.getElementById('spine-\(escaped)')?.scrollIntoView({block:'start'})")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.acceptSpineReports = true
        }
    }

    private func applySpine(_ index: Int, count: Int) {
        guard let epub = session.epub, epub.spine.indices.contains(index) else { return }
        let placements = SpineChapters.placements(spine: epub.spine, toc: epub.toc)
        let placement = placements[index]
        let title = placement.title.isEmpty ? epub.spine[index].title : placement.title
        session.updatePage(index + 1, count: count, section: title)
    }

    private func flash(_ quote: String) {
        let escaped = quote.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.webView?.evaluateJavaScript("window.readerFlash && window.readerFlash('\(escaped)')")
        }
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
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
            return "{\"id\":\"\(concept.id)\",\"color\":\"\(color)\",\"terms\":[\(terms)]}"
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
            body += "<section id=\"spine-\(item.id)\" data-index=\"\(index)\" data-chapter=\"\(chapter.map(String.init) ?? "")\"><h2>\(item.title)</h2>\(html)</section>"
        }
        let target = min(max(session.page - 1, 0), max(epub.spine.count - 1, 0))
        applySpine(target, count: epub.spine.count)
        let css = """
        body { font: \(16 * fontScale)px Georgia, serif; line-height: 1.6; margin: 48px auto; max-width: \(session.twoPages ? 920 : 680)px; \(columns) }
        .reader-hl { background: #F2C94C59; }
        .reader-word { border-bottom: 1.5px dotted #666; }
        .reader-note { border-left: 3px solid #888; margin: 8px 0; padding: 8px 10px; background: rgba(0,0,0,0.04); }
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
          return { text, index, prefix: node.slice(Math.max(0, start - 40), start), suffix: node.slice(start + text.length, start + text.length + 40), sentence: node.trim(), cfi: "epubcfi(/6/" + ((index + 1) * 2) + "!/4,/1:" + start + ",/1:" + (start + text.length) + ")" };
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
        const concepts = \(conceptScript());
        if (\(session.showConceptMarkers ? "true" : "false")) {
          concepts.forEach(concept => {
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            const nodes = [];
            while (walker.nextNode()) nodes.push(walker.currentNode);
            nodes.forEach(node => {
              if (!node.nodeValue || !node.parentNode || node.parentNode.closest && node.parentNode.closest(".reader-concept")) return;
              for (const term of concept.terms) {
                const at = node.nodeValue.toLowerCase().indexOf(term.toLowerCase());
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
