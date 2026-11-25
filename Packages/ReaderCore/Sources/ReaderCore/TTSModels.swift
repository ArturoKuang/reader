import Foundation

/// A range in UTF-16 code units, interchangeable with `NSRange`.
public struct TTSUTF16Range: Equatable, Hashable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    public var end: Int { location + length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

/// Where a segment lives in the source document. Offsets are relative to the
/// page or section text that was handed to the planner.
public enum TTSSegmentLocator: Equatable, Sendable {
    case pdf(pageIndex: Int, utf16Range: TTSUTF16Range)
    case web(sectionIndex: Int, textOffset: Int, textLength: Int)

    public var pageOrSectionIndex: Int {
        switch self {
        case .pdf(let pageIndex, _): return pageIndex
        case .web(let sectionIndex, _, _): return sectionIndex
        }
    }

    /// The segment's range within its page or section text.
    public var sourceRange: TTSUTF16Range {
        switch self {
        case .pdf(_, let range): return range
        case .web(_, let offset, let length): return TTSUTF16Range(location: offset, length: length)
        }
    }

    /// Converts a range relative to the segment text (such as the active word)
    /// into the same coordinate space as this locator.
    public func sourceRange(forSegmentRange range: TTSUTF16Range) -> TTSUTF16Range {
        TTSUTF16Range(location: sourceRange.location + range.location, length: range.length)
    }
}

public struct TTSDocumentSegment: Equatable, Sendable, Identifiable {
    public var id: String { "\(chapterIndex):\(segmentIndex)" }
    /// Position of the owning plan in the planner's chapter array.
    public internal(set) var chapterIndex: Int = 0
    /// Position of this segment within its chapter.
    public internal(set) var segmentIndex: Int = 0
    /// Clauses split from one long sentence share a sentence index.
    public let sentenceIndex: Int
    public let text: String
    /// Word ranges relative to `text`.
    public let wordRanges: [TTSUTF16Range]
    public let locator: TTSSegmentLocator
    /// Range of `text` inside `TTSChapterPlan.fullText`.
    public internal(set) var utf16RangeWithinChapter: TTSUTF16Range
    /// Seconds at 1.0x.
    public let estimatedDurationSec: TimeInterval
    /// Cumulative 1.0x seconds of all earlier segments in the chapter.
    public internal(set) var chapterStartOffset: TimeInterval = 0

    public var utf16Length: Int { text.utf16.count }
    public var wordCount: Int { wordRanges.count }

    public init(sentenceIndex: Int, text: String, wordRanges: [TTSUTF16Range], locator: TTSSegmentLocator) {
        self.sentenceIndex = sentenceIndex
        self.text = text
        self.wordRanges = wordRanges
        self.locator = locator
        utf16RangeWithinChapter = TTSUTF16Range(location: 0, length: text.utf16.count)
        estimatedDurationSec = TTSTimeEstimator.baseDuration(for: text)
    }
}

public struct TTSChapterPlan: Equatable, Sendable {
    public let chapterIndex: Int
    public let title: String
    public internal(set) var totalChapters: Int
    public let segments: [TTSDocumentSegment]
    /// Segment texts joined by newlines.
    public let fullText: String
    public let totalWordCount: Int
    /// Seconds at 1.0x.
    public let estimatedDurationSec: TimeInterval

    /// Assigns each segment its indices, chapter range and start time.
    public init(chapterIndex: Int, title: String, totalChapters: Int, segments: [TTSDocumentSegment]) {
        var placed = segments
        var location = 0
        var elapsed: TimeInterval = 0
        for index in placed.indices {
            placed[index].chapterIndex = chapterIndex
            placed[index].segmentIndex = index
            placed[index].utf16RangeWithinChapter = TTSUTF16Range(location: location, length: placed[index].utf16Length)
            placed[index].chapterStartOffset = elapsed
            location += placed[index].utf16Length + 1
            elapsed += placed[index].estimatedDurationSec
        }
        self.chapterIndex = chapterIndex
        self.title = title
        self.totalChapters = totalChapters
        self.segments = placed
        fullText = placed.map(\.text).joined(separator: "\n")
        totalWordCount = placed.reduce(0) { $0 + $1.wordCount }
        estimatedDurationSec = elapsed
    }

    /// The segment and offset for an offset into `fullText`, clamped to the chapter.
    public func position(atChapterOffset offset: Int) -> TTSSeekTarget? {
        guard let segment = segments.last(where: { $0.utf16RangeWithinChapter.location <= offset }) ?? segments.first else { return nil }
        let local = min(max(offset - segment.utf16RangeWithinChapter.location, 0), max(segment.utf16Length - 1, 0))
        return TTSSeekTarget(chapterIndex: chapterIndex, segmentIndex: segment.segmentIndex, charOffset: local)
    }

    /// Word or phrase match restricted to this chapter.
    public func locate(quote: String, prefix: String = "", suffix: String = "") -> TTSStartMatch? {
        TTSTextPlanner.findStartSegment(matchingQuote: quote, prefix: prefix, suffix: suffix, preferredPageOrSection: nil, in: [self])
    }

    public func locate(baseTime: TimeInterval) -> (segmentIndex: Int, wordUTF16Offset: Int) {
        let target = TTSTimeEstimator.position(atBaseTime: baseTime, in: self)
        return (target.segmentIndex, target.charOffset)
    }

    public func baseTime(segmentIndex: Int, utf16Offset: Int) -> TimeInterval {
        TTSTimeEstimator.elapsedBaseTime(segmentIndex: segmentIndex, charOffset: utf16Offset, in: self)
    }
}

public enum TTSPlaybackState: Equatable, Sendable {
    case idle
    case playing
    case paused
}

public enum TTSSpeedPreset: Double, CaseIterable, Sendable {
    case half = 0.5
    case threeQuarters = 0.75
    case normal = 1.0
    case oneAndQuarter = 1.25
    case oneAndHalf = 1.5
    case oneAndThreeQuarters = 1.75
    case double = 2.0
    case twoAndHalf = 2.5
    case triple = 3.0

    public var label: String { Self.label(for: rawValue) }

    /// `1x`, `1.25x`, `2.5x`.
    public static func label(for multiplier: Double) -> String {
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), multiplier)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "x"
    }
}

/// Maps a user speed multiplier onto a speech-synthesizer rate. The defaults
/// are the values of the AVFoundation utterance rate constants.
public enum TTSRateMapper {
    public static let presets: [Double] = TTSSpeedPreset.allCases.map(\.rawValue)
    public static let minMultiplier: Double = 0.5
    public static let maxMultiplier: Double = 3.0

    public static func clampedMultiplier(_ multiplier: Double) -> Double {
        guard !multiplier.isNaN else { return 1.0 }
        return min(max(multiplier, minMultiplier), maxMultiplier)
    }

    /// Calibration from SPEC 3.1: with the default parameters, 0.5x is 0.28,
    /// 1x is 0.50 and 3x is 0.86. Strictly increasing and continuous at 1x.
    public static func avRate(
        for multiplier: Double,
        minRate: Float = 0.0,
        defaultRate: Float = 0.5,
        maxRate: Float = 1.0
    ) -> Float {
        let value = clampedMultiplier(multiplier)
        let low = Double(minRate)
        let middle = Double(defaultRate)
        let high = Double(maxRate)
        let rate: Double
        if value <= 1 {
            rate = middle - 0.88 * (middle - low) * (1 - value)
        } else {
            let progress = log2(value) / log2(maxMultiplier)
            rate = middle + 0.72 * (high - middle) * pow(progress, 0.92)
        }
        return min(max(Float(rate), minRate), maxRate)
    }

    public static func formatMultiplier(_ multiplier: Double) -> String {
        TTSSpeedPreset.label(for: multiplier)
    }
}

/// A playback position.
public struct TTSSeekTarget: Equatable, Sendable {
    /// Position in the chapter array.
    public var chapterIndex: Int
    public var segmentIndex: Int
    /// UTF-16 offset within the segment text.
    public var charOffset: Int
    /// True when the request ran past the last speakable position; the other
    /// fields then point at the end of the final segment.
    public var reachedEnd: Bool

    public init(chapterIndex: Int, segmentIndex: Int, charOffset: Int, reachedEnd: Bool = false) {
        self.chapterIndex = chapterIndex
        self.segmentIndex = segmentIndex
        self.charOffset = charOffset
        self.reachedEnd = reachedEnd
    }
}

/// All times are "base" seconds (the 1.0x reference pace) unless a rate is passed.
public enum TTSTimeEstimator {
    private static let wordsPerSecond = 2.9
    private static let unitsPerSecond = 14.5
    private static let segmentPause = 0.2
    private static let tolerance = 1e-6

    /// Average of a word-count and a character-count estimate, plus a sentence pause.
    public static func baseDuration(for text: String) -> TimeInterval {
        let units = text.split(whereSeparator: \.isWhitespace).reduce(0) { $0 + $1.utf16.count }
        guard units > 0 else { return 0 }
        let words = TTSTextPlanner.wordRanges(in: text).count
        return 0.5 * (Double(words) / wordsPerSecond + Double(units) / unitsPerSecond) + segmentPause
    }

    /// `m:ss`, or `h:mm:ss` from one hour up.
    public static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? Int(min(max(seconds, 0), 359_999_999)) : 0
        let hours = total / 3600
        let minutes = total / 60 % 60
        let rest = String(format: "%02d", total % 60)
        if hours > 0 { return "\(hours):\(String(format: "%02d", minutes)):\(rest)" }
        return "\(minutes):\(rest)"
    }

    public static func elapsedBaseTime(segmentIndex: Int, charOffset: Int, in plan: TTSChapterPlan) -> TimeInterval {
        guard !plan.segments.isEmpty else { return 0 }
        if segmentIndex < 0 { return 0 }
        if segmentIndex >= plan.segments.count { return plan.estimatedDurationSec }
        let segment = plan.segments[segmentIndex]
        let length = max(segment.utf16Length, 1)
        let fraction = Double(min(max(charOffset, 0), length)) / Double(length)
        return segment.chapterStartOffset + fraction * segment.estimatedDurationSec
    }

    /// The word being spoken at `baseTime`, clamped to the chapter. A time at or
    /// past the end resolves to the last word with `reachedEnd` set.
    public static func position(atBaseTime baseTime: TimeInterval, in plan: TTSChapterPlan) -> TTSSeekTarget {
        guard !plan.segments.isEmpty else {
            return TTSSeekTarget(chapterIndex: plan.chapterIndex, segmentIndex: 0, charOffset: 0, reachedEnd: true)
        }
        let time = baseTime.isNaN ? 0 : min(max(baseTime, 0), plan.estimatedDurationSec)
        if time >= plan.estimatedDurationSec - tolerance { return end(of: plan) }
        // Binary search for the last segment starting at or before `time`.
        var low = 0
        var high = plan.segments.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if plan.segments[middle].chapterStartOffset <= time + tolerance {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let segment = plan.segments[low]
        let fraction = max(time - segment.chapterStartOffset, 0) / max(segment.estimatedDurationSec, tolerance)
        let offset = fraction * Double(segment.utf16Length) + tolerance
        // Leading punctuation belongs to the first word, so it starts at 0.
        let word = segment.wordRanges.dropFirst().last { Double($0.location) <= offset }
        return TTSSeekTarget(chapterIndex: plan.chapterIndex, segmentIndex: low, charOffset: word?.location ?? 0)
    }

    private static func end(of plan: TTSChapterPlan) -> TTSSeekTarget {
        let last = plan.segments.count - 1
        let offset = plan.segments[last].wordRanges.last?.location ?? 0
        return TTSSeekTarget(chapterIndex: plan.chapterIndex, segmentIndex: last, charOffset: offset, reachedEnd: true)
    }

    /// Scrubber position in `0...1`.
    public static func fraction(segmentIndex: Int, charOffset: Int, in plan: TTSChapterPlan) -> Double {
        guard plan.estimatedDurationSec > 0 else { return 0 }
        return elapsedBaseTime(segmentIndex: segmentIndex, charOffset: charOffset, in: plan) / plan.estimatedDurationSec
    }

    public static func seek(toFraction fraction: Double, in plan: TTSChapterPlan) -> TTSSeekTarget {
        let clamped = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        return position(atBaseTime: clamped * plan.estimatedDurationSec, in: plan)
    }

    /// Skips wall-clock seconds at `rate`. Going back less than two seconds into
    /// a chapter moves into the previous one; going past a chapter's end moves
    /// to the start of the next. `chapterIndex` indexes `chapters`.
    public static func skip(
        bySeconds delta: TimeInterval,
        chapterIndex: Int,
        segmentIndex: Int,
        charOffset: Int,
        rate: Double = 1.0,
        in chapters: [TTSChapterPlan]
    ) -> TTSSeekTarget? {
        guard chapters.indices.contains(chapterIndex) else { return nil }
        let multiplier = TTSRateMapper.clampedMultiplier(rate)
        let plan = chapters[chapterIndex]
        let now = elapsedBaseTime(segmentIndex: segmentIndex, charOffset: charOffset, in: plan)
        let target = now + delta * multiplier
        var result: TTSSeekTarget
        if delta < 0, chapterIndex > 0, now < 2 * multiplier {
            let previous = chapters[chapterIndex - 1]
            result = position(atBaseTime: previous.estimatedDurationSec + delta * multiplier, in: previous)
            result.chapterIndex = chapterIndex - 1
        } else if delta > 0, target >= plan.estimatedDurationSec, chapterIndex + 1 < chapters.count {
            result = position(atBaseTime: 0, in: chapters[chapterIndex + 1])
            result.chapterIndex = chapterIndex + 1
        } else {
            result = position(atBaseTime: target, in: plan)
            result.chapterIndex = chapterIndex
        }
        return result
    }
}
