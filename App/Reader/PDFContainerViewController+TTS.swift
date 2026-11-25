import AppKit
import PDFKit
import ReaderCore

/// Read Aloud for PDFs. The sentence and word are drawn by `PDFTTSOverlay`;
/// PDFKit's own annotations are never touched.
extension PDFContainerViewController: TTSDocumentBridge {
    /// How long after the bridge moves the view that scrolling still counts as its own.
    static let programmaticScrollWindow: TimeInterval = 0.55

    // MARK: Plan

    func buildTTSChapters(completion: @escaping ([TTSChapterPlan]) -> Void) {
        guard let document = pdfView.document else { return completion([]) }
        // PDFKit text extraction stays on the main thread; only the planning moves off it.
        let pages = (0..<document.pageCount).map {
            TTSTextPlanner.PageSource(pageIndex: $0, text: document.page(at: $0)?.string ?? "")
        }
        let outline = session.outline.compactMap { row in
            row.page.map { TTSTextPlanner.OutlineBound(title: row.title, startPageIndex: $0 - 1) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let plans = TTSTextPlanner.planPDF(pages: pages, outline: outline)
            DispatchQueue.main.async { completion(plans) }
        }
    }

    func currentTTSViewportStart(in chapters: [TTSChapterPlan]) -> (chapterIndex: Int, segmentIndex: Int, utf16Offset: Int) {
        guard let document = pdfView.document, let current = pdfView.currentPage else { return (0, 0, 0) }
        let pageIndex = document.index(for: current)
        let visibleTop = pdfView.convert(pdfView.bounds, to: current).maxY
        var last = (chapterIndex: 0, segmentIndex: 0, utf16Offset: 0)
        for (chapterIndex, chapter) in chapters.enumerated() {
            for (segmentIndex, segment) in chapter.segments.enumerated() {
                guard case .pdf(let segmentPage, let range) = segment.locator else { continue }
                last = (chapterIndex, segmentIndex, 0)
                if segmentPage < pageIndex { continue }
                // The first segment after the current page, when the page itself has no text left.
                if segmentPage > pageIndex { return last }
                guard let bounds = lineBounds(of: range.nsRange, on: current) else { continue }
                // Its middle is at or below the top edge, so a line cut off above is skipped.
                if bounds.midY <= visibleTop { return last }
            }
        }
        return last
    }

    // MARK: Highlight

    func applyTTSHighlight(chapter: TTSChapterPlan, segment: TTSDocumentSegment, wordRangeInSegment: NSRange?, autoScroll: Bool) {
        guard case .pdf(let pageIndex, let range) = segment.locator, let page = pdfView.document?.page(at: pageIndex) else {
            ttsOverlay.highlight = nil
            return
        }
        let sentenceRange = range.nsRange
        let sentence: [NSRect]
        if let cached = ttsSentenceCache, cached.pageIndex == pageIndex, cached.range == sentenceRange {
            sentence = cached.rects
        } else {
            sentence = lineRects(of: sentenceRange, on: page)
            ttsSentenceCache = (pageIndex, sentenceRange, sentence)
        }
        let word = wordRangeInSegment.map {
            lineRects(of: segment.locator.sourceRange(forSegmentRange: TTSUTF16Range($0)).nsRange, on: page)
        } ?? []
        ttsOverlay.highlight = PDFTTSOverlay.Highlight(page: page, sentence: sentence, word: word)
        if autoScroll { revealTTSHighlight(force: false, animated: true) }
    }

    func clearTTSHighlight() {
        ttsOverlay.highlight = nil
        ttsSentenceCache = nil
    }

    func scrollToActiveTTSHighlight(animated: Bool) {
        revealTTSHighlight(force: true, animated: animated)
    }

    func setTTSBottomInset(_ inset: CGFloat) {
        ttsSessionActive = inset > 0
        guard let scroll = enclosingScrollClip(in: pdfView)?.enclosingScrollView else { return }
        beginTTSProgrammaticScroll()
        scroll.automaticallyAdjustsContentInsets = false
        var insets = scroll.contentInsets
        insets.bottom = inset
        scroll.contentInsets = insets
    }

    /// PDF pages stay white, so the pill only follows the window's appearance.
    var preferredTTSAppearanceIsDark: Bool {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: Scrolling

    /// Marks the next scroll notifications as the bridge's own.
    func beginTTSProgrammaticScroll(_ duration: TimeInterval = PDFContainerViewController.programmaticScrollWindow) {
        ttsProgrammaticUntil = max(ttsProgrammaticUntil, Date().addingTimeInterval(duration))
    }

    /// True for a scroll the user did, which detaches follow-text.
    func reportUserScrollIfNeeded(always: Bool = false) {
        guard ttsSessionActive, always || Date() > ttsProgrammaticUntil else { return }
        onManualScrollDuringTTS?()
    }

    /// Moves the active line to about 36% from the top when it left the reading band.
    private func revealTTSHighlight(force: Bool, animated: Bool) {
        guard let highlight = ttsOverlay.highlight, let line = highlight.word.first ?? highlight.sentence.first else { return }
        let continuous = pdfView.displayMode == .singlePageContinuous || pdfView.displayMode == .twoUpContinuous
        if !continuous, !pdfView.visiblePages.contains(highlight.page) {
            beginTTSProgrammaticScroll()
            pdfView.go(to: highlight.page)
            pdfView.layoutSubtreeIfNeeded()
        }
        guard let rect = ttsOverlay.viewRects([line], on: highlight.page).first,
              let clip = enclosingScrollClip(in: pdfView) else { return }
        let height = ttsOverlay.bounds.height
        guard height > 0 else { return }
        let inBand = rect.minY >= height * 0.18 && rect.maxY <= height * 0.65
        guard force || !inBand else { return }

        let delta = rect.minY - height * 0.36
        var origin = clip.bounds.origin
        origin.y += (clip.documentView?.isFlipped ?? true) ? delta : -delta
        origin = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard abs(origin.y - clip.bounds.origin.y) > 0.5 else { return }

        beginTTSProgrammaticScroll()
        let scroll = clip.enclosingScrollView
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: {
                scroll?.reflectScrolledClipView(clip)
            }
        } else {
            clip.setBoundsOrigin(origin)
            scroll?.reflectScrolledClipView(clip)
        }
    }

    // MARK: Geometry

    /// `range` clipped to the page text. PDFKit returns nothing for ranges past the end.
    private func clamped(_ range: NSRange, on page: PDFPage) -> NSRange? {
        let length = ((page.string ?? "") as NSString).length
        guard range.location >= 0, range.location < length else { return nil }
        let clipped = NSRange(location: range.location, length: min(range.length, length - range.location))
        return clipped.length > 0 ? clipped : nil
    }

    private func lineRects(of range: NSRange, on page: PDFPage) -> [NSRect] {
        guard let range = clamped(range, on: page), let selection = page.selection(for: range) else { return [] }
        return selection.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0 && $0.height > 0 }
    }

    private func lineBounds(of range: NSRange, on page: PDFPage) -> NSRect? {
        lineRects(of: range, on: page).first
    }
}
