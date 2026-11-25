import AppKit
import ReaderCore
import WebKit

/// A web view that adds "Read Aloud from Here" to its context menu.
final class ReaderWebView: WKWebView {
    /// Gets the click point in CSS pixels.
    var onReadAloudFromHere: ((CGPoint) -> Void)?
    private var contextPoint = CGPoint.zero
    static let readAloudTitle = "Read Aloud from Here"

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let point = convert(event.locationInWindow, from: nil)
        contextPoint = CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
        menu.items.filter { $0.title == Self.readAloudTitle }.forEach { menu.removeItem($0) }
        let item = NSMenuItem(title: Self.readAloudTitle, action: #selector(readAloudFromHere(_:)), keyEquivalent: "r")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        // Below Copy and Look Up when WebKit offers them, otherwise first.
        let anchor = menu.items.lastIndex { item in
            let identifier = item.identifier?.rawValue ?? ""
            return identifier == "WKMenuItemIdentifierCopy" || identifier == "WKMenuItemIdentifierLookUp"
                || item.title == "Copy" || item.title.hasPrefix("Look Up")
        }
        if let anchor {
            menu.insertItem(item, at: anchor + 1)
        } else {
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
    }

    @objc private func readAloudFromHere(_ sender: Any?) {
        onReadAloudFromHere?(contextPoint)
    }
}

/// What the page last painted, so it can be repainted after a page load or a scroll back.
struct TTSWebHighlight: Equatable {
    var section: Int
    var sentence: TTSUTF16Range
    var word: TTSUTF16Range?
    var autoScroll: Bool
}

/// Read Aloud for EPUB and Markdown. The page does the painting (`WebTTSScript`);
/// the plan is built from the same DOM text it paints against.
extension WebDocumentContainerViewController: TTSDocumentBridge {
    // MARK: Plan

    func buildTTSChapters(completion: @escaping ([TTSChapterPlan]) -> Void) {
        guard let webView, spineLoaded else { return completion([]) }
        let titles = ttsSectionTitles()
        webView.callAsyncJavaScript(
            "return { sections: window.readerTTSExtractSections(extra), viewport: window.readerTTSViewportStart() };",
            arguments: ["extra": offscreenSpineSections()], in: nil, in: .page
        ) { [weak self] result in
            guard let self, case .success(let value) = result, let object = value as? [String: Any],
                  let rows = object["sections"] as? [[String: Any]] else { return completion([]) }
            if let viewport = object["viewport"] as? [String: Any],
               let section = self.integer(viewport["sectionIndex"]), let offset = self.integer(viewport["offset"]) {
                self.ttsViewport = (section, offset)
            } else {
                self.ttsViewport = nil
            }
            let sources = rows.compactMap { row -> TTSTextPlanner.WebSectionSource? in
                guard let index = self.integer(row["index"]), let text = row["text"] as? String else { return nil }
                return TTSTextPlanner.WebSectionSource(sectionIndex: index, title: titles(index), text: text)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let plans = TTSTextPlanner.planWeb(sections: sources)
                DispatchQueue.main.async { completion(plans) }
            }
        }
    }

    /// The spine items that are not in the page. Single and two-page EPUB load only one or two,
    /// and the voice still has to read on from them; the page parses these without showing them.
    private func offscreenSpineSections() -> [[String: Any]] {
        guard let epub = session.epub, !session.continuous else { return [] }
        let loaded: Set<Int>
        if session.twoPages {
            let start = max(session.page - 1, 0)
            loaded = Set(start..<min(start + 2, epub.spine.count))
        } else {
            loaded = [min(max(session.page - 1, 0), max(epub.spine.count - 1, 0))]
        }
        return epub.spine.enumerated().compactMap { index, item in
            guard !loaded.contains(index), epub.xhtml(for: item.href) != nil else { return nil }
            return ["index": index, "html": spineSectionHTML(item, in: epub)]
        }
    }

    private func ttsSectionTitles() -> (Int) -> String {
        if let model = session.markdown {
            return { index in
                let title = model.sections.indices.contains(index) ? model.sections[index].title : ""
                return title.isEmpty ? model.title : title
            }
        }
        guard let epub = session.epub else { return { _ in "" } }
        let placements = SpineChapters.placements(spine: epub.spine, toc: epub.toc)
        return { index in
            guard placements.indices.contains(index) else { return "Section \(index + 1)" }
            let title = placements[index].title.isEmpty ? epub.spine[index].title : placements[index].title
            return title.isEmpty ? "Section \(index + 1)" : title
        }
    }

    /// `buildTTSChapters` read the viewport in the same page round trip as the text,
    /// because a page can only be asked asynchronously.
    func currentTTSViewportStart(in chapters: [TTSChapterPlan]) -> (chapterIndex: Int, segmentIndex: Int, utf16Offset: Int) {
        var first: (chapterIndex: Int, segmentIndex: Int, utf16Offset: Int)?
        var last = first
        for (chapterIndex, chapter) in chapters.enumerated() {
            for (segmentIndex, segment) in chapter.segments.enumerated() {
                guard case .web(let section, let start, let length) = segment.locator else { continue }
                first = first ?? (chapterIndex, segmentIndex, 0)
                last = (chapterIndex, segmentIndex, 0)
                guard let viewport = ttsViewport, section >= viewport.section else { continue }
                if section > viewport.section { return (chapterIndex, segmentIndex, 0) }
                guard start + length > viewport.offset else { continue }
                // Begin at a word, not in the middle of one.
                let inside = max(viewport.offset - start, 0)
                let word = segment.wordRanges.first { $0.end > inside }?.location ?? 0
                return (chapterIndex, segmentIndex, inside == 0 ? 0 : word)
            }
        }
        // Past the end of the text, the last sentence is the nearest one.
        return (ttsViewport == nil ? first : last) ?? (0, 0, 0)
    }

    // MARK: Highlight

    func applyTTSHighlight(chapter: TTSChapterPlan, segment: TTSDocumentSegment, wordRangeInSegment: NSRange?, autoScroll: Bool) {
        guard case .web(let section, let offset, let length) = segment.locator else { return }
        let highlight = TTSWebHighlight(
            section: section,
            sentence: TTSUTF16Range(location: offset, length: length),
            word: wordRangeInSegment.map { segment.locator.sourceRange(forSegmentRange: TTSUTF16Range($0)) },
            autoScroll: autoScroll
        )
        ttsActiveHighlight = highlight
        paint(highlight)
    }

    private func paint(_ highlight: TTSWebHighlight) {
        guard let webView, spineLoaded else { return }
        let word = highlight.word
        webView.callAsyncJavaScript(
            "return window.readerTTSHighlight(section, sentenceStart, sentenceLength, wordStart, wordLength, autoScroll);",
            arguments: [
                "section": highlight.section, "sentenceStart": highlight.sentence.location, "sentenceLength": highlight.sentence.length,
                "wordStart": word?.location ?? -1, "wordLength": word?.length ?? 0, "autoScroll": highlight.autoScroll,
            ],
            in: nil, in: .page
        ) { [weak self] result in
            // A newer highlight owns the page by now.
            guard let self, self.ttsActiveHighlight == highlight, case .success(let status) = result else { return }
            switch status as? String {
            case "missing":
                // The next chapter of a single-page EPUB is a different document. Only a follow
                // request moves the page; a reader who scrolled away is left where they are.
                if highlight.autoScroll { self.loadSectionForTTS(highlight.section) }
            case "stale":
                self.onTTSContentInvalidated?()
            default:
                break
            }
        }
    }

    private func loadSectionForTTS(_ index: Int) {
        guard session.epub != nil, !session.continuous, ttsPendingSection != index else { return }
        ttsPendingSection = index
        showSection(index: index)
    }

    /// A new page replaces the old one's TTS state, so put it back.
    func resumeTTSAfterLoad() {
        ttsPendingSection = nil
        guard ttsBottomInset > 0 else { return }
        webView?.evaluateJavaScript("window.readerTTSSetBottomInset(\(Double(ttsBottomInset)))")
        if var highlight = ttsActiveHighlight {
            highlight.autoScroll = true
            ttsActiveHighlight = highlight
            paint(highlight)
        }
    }

    func clearTTSHighlight() {
        ttsActiveHighlight = nil
        ttsPendingSection = nil
        webView?.evaluateJavaScript("window.readerTTSClear && window.readerTTSClear()")
    }

    func scrollToActiveTTSHighlight(animated: Bool) {
        guard var highlight = ttsActiveHighlight, let webView else { return }
        webView.callAsyncJavaScript("return window.readerTTSScrollToActive ? window.readerTTSScrollToActive(animated) : false;", arguments: ["animated": animated], in: nil, in: .page) { [weak self] result in
            guard let self, case .success(let value) = result, (value as? Bool) != true else { return }
            // Nothing painted on this page yet; paint and follow.
            highlight.autoScroll = true
            self.ttsActiveHighlight = highlight
            self.paint(highlight)
        }
    }

    func setTTSBottomInset(_ inset: CGFloat) {
        ttsBottomInset = inset
        if inset == 0 { ttsViewport = nil }
        webView?.evaluateJavaScript("window.readerTTSSetBottomInset(\(Double(inset)))")
    }

    var preferredTTSAppearanceIsDark: Bool {
        (view.window?.effectiveAppearance ?? view.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: Context menu

    /// Selects the word under the pointer unless there is a selection, then reads from it.
    func readAloudFromContextMenu(at point: CGPoint) {
        guard let webView else { return }
        webView.callAsyncJavaScript(
            "return window.readerTTSSelectAt ? window.readerTTSSelectAt(x, y) : false;",
            arguments: ["x": Double(point.x), "y": Double(point.y)], in: nil, in: .page
        ) { [weak self] _ in
            guard let self else { return }
            // A selection from an earlier click must not become the start.
            self.session.selection = nil
            self.captureSelection { [weak self] in self?.session.onReadFromSelection?() }
        }
    }
}
