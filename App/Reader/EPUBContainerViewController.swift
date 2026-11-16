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
    func nextPage() { session.page = min(session.page + 1, session.pageCount); loadSpine() }
    func previousPage() { session.page = max(session.page - 1, 1); loadSpine() }
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
        webView?.evaluateJavaScript("window.readerSelection && window.readerSelection()") { [weak self] result, _ in
            guard let self, let object = result as? [String: Any], let text = object["text"] as? String, !text.isEmpty else { return }
            Task { @MainActor in
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
        }
    }

    func reveal(_ position: ReadingPosition) {
        if let page = position.page { session.page = page }
        loadSpine()
        if let quote = position.quote, !quote.isEmpty {
            let escaped = quote.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            webView?.evaluateJavaScript("window.find('\(escaped)')")
        }
    }

    func consumePendingJump() {
        guard let link = session.pendingReaderLink else { return }
        session.pendingReaderLink = nil
        if let location = link.location, let cfi = EPUBCFI(value: location), let index = cfi.spineIndex {
            session.page = index + 1
            loadSpine()
        }
        let quote = session.highlights.first { $0.id == link.id }?.quote ?? session.notes.first { $0.id == link.id }?.quote ?? ""
        guard !quote.isEmpty else { return }
        let escaped = quote.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.webView?.evaluateJavaScript("window.readerFlash && window.readerFlash('\(escaped)')")
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
        var body = ""
        for item in items {
            let html = epub.xhtml(for: item.href) ?? "<p>Missing \(item.href)</p>"
            body += "<section id=\"spine-\(item.id)\"><h2>\(item.title)</h2>\(html)</section>"
        }
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
          return { text, prefix: node.slice(Math.max(0, start - 40), start), suffix: node.slice(start + text.length, start + text.length + 40), sentence: node.trim(), cfi: "epubcfi(/6/\((max(session.page - 1, 0) + 1) * 2)!/4,/1:" + start + ",/1:" + (start + text.length) + ")" };
        };
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
