import Foundation
import ReaderCore

/// What a document pane provides so `TTSEngine` can read it aloud. All calls,
/// including the `buildTTSChapters` completion, happen on the main thread.
@MainActor
protocol TTSDocumentBridge: AnyObject {
    /// Chapter plans whose locators match the live rendered document.
    func buildTTSChapters(completion: @escaping ([TTSChapterPlan]) -> Void)
    /// The first visible position. `chapterIndex` indexes `chapters`.
    func currentTTSViewportStart(in chapters: [TTSChapterPlan]) -> (chapterIndex: Int, segmentIndex: Int, utf16Offset: Int)
    /// Like `currentTTSViewportStart`, but asks the live document first.
    func resolveCurrentTTSViewportStart(in chapters: [TTSChapterPlan], completion: @escaping ((chapterIndex: Int, segmentIndex: Int, utf16Offset: Int)) -> Void)
    /// Paints the sentence and, when known, the spoken word (relative to `segment.text`).
    /// Scrolls to keep it visible only when `autoScroll` is true.
    func applyTTSHighlight(chapter: TTSChapterPlan, segment: TTSDocumentSegment, wordRangeInSegment: NSRange?, autoScroll: Bool)
    func clearTTSHighlight()
    func scrollToActiveTTSHighlight(animated: Bool)
    /// Extra bottom scroll padding while the player covers the pane; 0 restores it.
    func setTTSBottomInset(_ inset: CGFloat)
    /// Called for user-initiated scrolls only, never for the bridge's own scrolling.
    var onManualScrollDuringTTS: (() -> Void)? { get set }
    var preferredTTSAppearanceIsDark: Bool { get }
}

extension TTSDocumentBridge {
    func resolveCurrentTTSViewportStart(in chapters: [TTSChapterPlan], completion: @escaping ((chapterIndex: Int, segmentIndex: Int, utf16Offset: Int)) -> Void) {
        completion(currentTTSViewportStart(in: chapters))
    }
}
