import XCTest
@testable import ReaderCore

final class TTSTests: XCTestCase {
    private func sentences(_ text: String, max: Int = 360, lineBreaks: TTSTextPlanner.LineBreaks = .boundary) -> [String] {
        TTSTextPlanner.segmentText(text, maxUTF16Length: max, lineBreaks: lineBreaks).map(\.text)
    }

    private func slice(_ text: String, _ range: TTSUTF16Range) -> String {
        (text as NSString).substring(with: range.nsRange)
    }

    private func web(_ texts: String...) -> [TTSChapterPlan] {
        TTSTextPlanner.planWeb(sections: texts.enumerated().map {
            .init(sectionIndex: $0.offset, title: "S\($0.offset)", text: $0.element)
        })
    }

    private func word(_ match: TTSStartMatch, in plans: [TTSChapterPlan]) -> String {
        let text = plans[match.target.chapterIndex].segments[match.target.segmentIndex].text
        return String((text as NSString).substring(from: match.target.charOffset).prefix { $0.isLetter })
    }

    // MARK: - Segmentation

    func testAbbreviationsAndDecimalsDoNotSplit() {
        let text = "Dr. Smith met Mr. Jones, Mrs. Lee, Ms. Wu and Prof. Kim. "
            + "Use tools, e.g. Swift, i.e. Apple's, vs. others in the U.S. Government. "
            + "See Fig. 3 by Doe et al. (2020), where pi is 3.14 exactly. J. K. Rowling agreed."
        XCTAssertEqual(sentences(text), [
            "Dr. Smith met Mr. Jones, Mrs. Lee, Ms. Wu and Prof. Kim.",
            "Use tools, e.g. Swift, i.e. Apple's, vs. others in the U.S. Government.",
            "See Fig. 3 by Doe et al. (2020), where pi is 3.14 exactly.",
            "J. K. Rowling agreed.",
        ])
    }

    func testTerminatorsQuotesAndLooseAbbreviations() {
        XCTAssertEqual(sentences("We left the U.S. The trip was long."), ["We left the U.S.", "The trip was long."])
        XCTAssertEqual(sentences("\"Why?\" she asked. “Stop!” He did... Then 1. no"), ["\"Why?\" she asked.", "“Stop!”", "He did...", "Then 1. no"])
        XCTAssertEqual(sentences("1. Intro text. Visit example.com today."), ["1. Intro text.", "Visit example.com today."])
        XCTAssertEqual(sentences("今天很好。明天呢？好！"), ["今天很好。", "明天呢？", "好！"])
    }

    func testLineBreakModesAndUnspeakableSegments() {
        XCTAssertEqual(sentences("Title\nBody here.\n\n***\n"), ["Title", "Body here."])
        XCTAssertEqual(sentences("A wrapped\nline here.\n\nHeading\n \nNext.", lineBreaks: .soft), ["A wrapped\nline here.", "Heading", "Next."])
        XCTAssertEqual(sentences(""), [])
        XCTAssertEqual(sentences("  \n \n"), [])
    }

    func testUTF16OffsetsWithMultiByteText() {
        let text = "  “Héllo” — world 👩‍👩‍👧 said. It’s 🎉 done!\r\n中文句子。 Cafe\u{301} ends."
        let segments = TTSTextPlanner.segmentText(text)
        XCTAssertEqual(segments.map(\.text), ["“Héllo” — world 👩‍👩‍👧 said.", "It’s 🎉 done!", "中文句子。", "Cafe\u{301} ends."])
        var previousEnd = 0
        for segment in segments {
            XCTAssertEqual(Array(slice(text, segment.range).utf16), Array(segment.text.utf16))
            XCTAssertGreaterThanOrEqual(segment.range.location, previousEnd)
            previousEnd = segment.range.end
        }
        XCTAssertEqual(segments[0].words.map { slice(segments[0].text, $0) }, ["Héllo", "world", "said"])
        XCTAssertEqual(segments[1].words.map { slice(segments[1].text, $0) }, ["It’s", "done"])
        XCTAssertEqual(segments[0].range.location, 2)
    }

    func testLongSentenceSplitsOnClauseMarks() {
        let clause = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let text = "\(clause); \(clause): \(clause)— \(clause), \(clause)."
        let segments = TTSTextPlanner.segmentText(text)
        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(segments.allSatisfy { $0.range.length <= 360 })
        XCTAssertEqual(segments.map { $0.text.last }, [":", "—", "."])
        for segment in segments { XCTAssertEqual(slice(text, segment.range), segment.text) }
        XCTAssertEqual(segments.reduce(0) { $0 + $1.words.count }, 150)

        let plan = web(text)[0]
        XCTAssertEqual(Set(plan.segments.map(\.sentenceIndex)), [0])
    }

    func testLongSplitProtectsNumbersAndNeverBreaksGraphemes() {
        let numbers = sentences("aaaa bbbb cost 3,000 dollars total", max: 20)
        XCTAssertEqual(numbers, ["aaaa bbbb cost", "3,000 dollars total"])
        let emoji = String(repeating: "👩‍👩‍👧", count: 10)
        let parts = sentences(emoji, max: 20)
        XCTAssertEqual(parts.joined(), emoji)
        XCTAssertTrue(parts.allSatisfy { $0.utf16.count <= 20 && $0.count == 2 })
    }

    // MARK: - Speed and time

    func testRateMapper() {
        let rates = TTSRateMapper.presets.map { TTSRateMapper.avRate(for: $0) }
        XCTAssertEqual(TTSRateMapper.presets, [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0])
        for (rate, expected) in zip(rates, [0.28, 0.39, 0.50, 0.583, 0.644, 0.693, 0.735, 0.804, 0.860] as [Float]) {
            XCTAssertEqual(rate, expected, accuracy: 0.002)
        }
        XCTAssertEqual(TTSRateMapper.avRate(for: 1), 0.5)
        var previous: Float = 0
        for step in 50...300 {
            let rate = TTSRateMapper.avRate(for: Double(step) / 100)
            XCTAssertGreaterThan(rate, previous)
            previous = rate
        }
        XCTAssertEqual(TTSRateMapper.avRate(for: -4), TTSRateMapper.avRate(for: 0.5))
        XCTAssertEqual(TTSRateMapper.avRate(for: 99), TTSRateMapper.avRate(for: 3))
        XCTAssertEqual(TTSRateMapper.avRate(for: .nan), 0.5)
        XCTAssertEqual(TTSRateMapper.avRate(for: 1, minRate: 0.1, defaultRate: 0.4, maxRate: 0.6), 0.4)
        for multiplier in TTSRateMapper.presets {
            let rate = TTSRateMapper.avRate(for: multiplier, minRate: 0.3, defaultRate: 0.4, maxRate: 0.6)
            XCTAssertTrue((0.3...0.6).contains(rate))
        }
    }

    func testSpeedLabelsAndTimeFormatting() {
        XCTAssertEqual(TTSSpeedPreset.allCases.map(\.label), ["0.5x", "0.75x", "1x", "1.25x", "1.5x", "1.75x", "2x", "2.5x", "3x"])
        XCTAssertEqual(TTSRateMapper.formatMultiplier(2.0), "2x")
        let cases: [(TimeInterval, String)] = [
            (0, "0:00"), (-3, "0:00"), (63.9, "1:03"), (65, "1:05"), (600, "10:00"), (1059, "17:39"),
            (3600, "1:00:00"), (3725, "1:02:05"), (.nan, "0:00"),
        ]
        for (seconds, text) in cases { XCTAssertEqual(TTSTimeEstimator.formatElapsed(seconds), text) }
        XCTAssertEqual(TTSTimeEstimator.baseDuration(for: "  "), 0)
        XCTAssertGreaterThan(TTSTimeEstimator.baseDuration(for: "one two three"), TTSTimeEstimator.baseDuration(for: "one"))
    }

    private func longChapters() -> [TTSChapterPlan] {
        let text = (1...20).map { "“Sentence number \($0) has several plain words in it.”" }.joined(separator: " ")
        return web(text, text)
    }

    func testPlanInvariants() {
        let plans = longChapters()
        XCTAssertEqual(plans.map(\.totalChapters), [2, 2])
        let plan = plans[1]
        XCTAssertEqual(plan.segments.count, 20)
        XCTAssertEqual(plan.totalWordCount, 180)
        XCTAssertEqual(plan.segments[3].id, "1:3")
        XCTAssertEqual(plan.estimatedDurationSec, plan.segments.reduce(0) { $0 + $1.estimatedDurationSec }, accuracy: 1e-9)
        for segment in plan.segments {
            XCTAssertEqual(slice(plan.fullText, segment.utf16RangeWithinChapter), segment.text)
        }
        let fourth = plan.segments[3].utf16RangeWithinChapter.location
        XCTAssertEqual(plan.position(atChapterOffset: fourth + 4), TTSSeekTarget(chapterIndex: 1, segmentIndex: 3, charOffset: 4))
        XCTAssertEqual(plan.locate(quote: "number 7 has")?.target.segmentIndex, 6)
    }

    func testScrubberRoundTrip() {
        let plan = longChapters()[0]
        for (index, segment) in plan.segments.enumerated() {
            for (wordIndex, range) in segment.wordRanges.enumerated() {
                let offset = wordIndex == 0 ? 0 : range.location
                let fraction = TTSTimeEstimator.fraction(segmentIndex: index, charOffset: offset, in: plan)
                let target = TTSTimeEstimator.seek(toFraction: fraction, in: plan)
                XCTAssertEqual(target, TTSSeekTarget(chapterIndex: 0, segmentIndex: index, charOffset: offset))
            }
        }
        XCTAssertEqual(TTSTimeEstimator.seek(toFraction: -1, in: plan), TTSSeekTarget(chapterIndex: 0, segmentIndex: 0, charOffset: 0))
        let end = TTSTimeEstimator.seek(toFraction: 2, in: plan)
        XCTAssertTrue(end.reachedEnd)
        XCTAssertEqual(end.segmentIndex, 19)
        XCTAssertEqual(plan.locate(baseTime: plan.baseTime(segmentIndex: 5, utf16Offset: 0)).segmentIndex, 5)
    }

    func testSkipWithinAndAcrossChapters() throws {
        let plans = longChapters()
        let total = plans[0].estimatedDurationSec
        func skip(_ delta: TimeInterval, _ chapter: Int, _ time: TimeInterval, rate: Double = 1) throws -> TTSSeekTarget {
            let at = plans[chapter].locate(baseTime: time)
            return try XCTUnwrap(TTSTimeEstimator.skip(bySeconds: delta, chapterIndex: chapter, segmentIndex: at.segmentIndex,
                                                       charOffset: at.wordUTF16Offset, rate: rate, in: plans))
        }
        func time(_ target: TTSSeekTarget) -> TimeInterval {
            plans[target.chapterIndex].baseTime(segmentIndex: target.segmentIndex, utf16Offset: target.charOffset)
        }
        XCTAssertEqual(time(try skip(15, 0, 20)), 35, accuracy: 1)
        XCTAssertEqual(time(try skip(-15, 0, 30)), 15, accuracy: 1)
        XCTAssertEqual(time(try skip(15, 0, 10, rate: 2)), 40, accuracy: 1.5)
        // Start of the book clamps.
        XCTAssertEqual(try skip(-15, 0, 5), TTSSeekTarget(chapterIndex: 0, segmentIndex: 0, charOffset: 0))
        // More than two seconds into a later chapter clamps to its start.
        XCTAssertEqual(try skip(-15, 1, 5), TTSSeekTarget(chapterIndex: 1, segmentIndex: 0, charOffset: 0))
        // Barely into it moves back.
        let back = try skip(-15, 1, 0)
        XCTAssertEqual(back.chapterIndex, 0)
        XCTAssertEqual(time(back), total - 15, accuracy: 1)
        XCTAssertEqual(try skip(15, 0, total - 3), TTSSeekTarget(chapterIndex: 1, segmentIndex: 0, charOffset: 0))
        let end = try skip(15, 1, total - 3)
        XCTAssertTrue(end.reachedEnd)
        XCTAssertEqual(end.chapterIndex, 1)
        XCTAssertEqual(end.segmentIndex, 19)
        XCTAssertNil(TTSTimeEstimator.skip(bySeconds: 15, chapterIndex: 5, segmentIndex: 0, charOffset: 0, in: plans))
    }

    // MARK: - Chapter planning

    private let pages: [TTSTextPlanner.PageSource] = [
        .init(pageIndex: 0, text: "Cover 📘 page."),
        .init(pageIndex: 1, text: "Chapter one starts with a wrapped\nline. Then more."),
        .init(pageIndex: 2, text: "It continues here."),
        .init(pageIndex: 3, text: "  "),
        .init(pageIndex: 4, text: "Chapter two."),
    ]

    func testPDFPlanWithOutline() {
        let plans = TTSTextPlanner.planPDF(pages: pages, outline: [
            .init(title: "Two", startPageIndex: 3), .init(title: "One", startPageIndex: 1),
            .init(title: "One, subsection", startPageIndex: 1), .init(title: "Broken", startPageIndex: 99),
        ])
        XCTAssertEqual(plans.map(\.title), ["Page 1", "One", "Two"])
        XCTAssertEqual(plans.map(\.chapterIndex), [0, 1, 2])
        XCTAssertEqual(plans[1].segments.map(\.text), ["Chapter one starts with a wrapped line.", "Then more.", "It continues here."])
        XCTAssertEqual(plans[1].segments.map(\.sentenceIndex), [0, 1, 2])
        XCTAssertEqual(plans[2].segments.map(\.locator.pageOrSectionIndex), [4])
        for segment in plans.flatMap(\.segments) {
            guard case .pdf(let page, let range) = segment.locator else { return XCTFail("not a PDF locator") }
            XCTAssertEqual(slice(pages[page].text, range).replacingOccurrences(of: "\n", with: " "), segment.text)
            let word = segment.wordRanges[0]
            XCTAssertEqual(slice(pages[page].text, segment.locator.sourceRange(forSegmentRange: word)), slice(segment.text, word))
        }
    }

    func testPDFPlanWithoutOutline() {
        let chunked = TTSTextPlanner.planPDF(pages: pages, outline: [], fallbackChunkSize: 2)
        XCTAssertEqual(chunked.map(\.title), ["Pages 1–2", "Pages 3–4", "Page 5"])
        let single = TTSTextPlanner.planPDF(pages: pages, outline: [], fallbackChunkSize: 1)
        XCTAssertEqual(single.map(\.title), ["Page 1", "Page 2", "Page 3", "Page 5"])
        XCTAssertEqual(single.map(\.totalChapters), [4, 4, 4, 4])
        XCTAssertEqual(TTSTextPlanner.planPDF(pages: pages, outline: []).count, 1)
        XCTAssertTrue(TTSTextPlanner.planPDF(pages: [.init(pageIndex: 0, text: " ")], outline: []).isEmpty)
        XCTAssertTrue(TTSTextPlanner.planPDF(pages: [], outline: []).isEmpty)
    }

    func testMarkdownPlanExcludesFrontMatter() {
        let source = "---\ntitle: My Doc\nsecretkey: hiddenvalue\n---\nIntro text.\n\n# First\nAlpha. Beta.\n\n## Second\n- item one\n- item two\n"
        let model = MarkdownDocumentModel.parse(source: source, fileName: "/docs/Note.md")
        let plans = TTSTextPlanner.planMarkdown(model)
        XCTAssertEqual(plans.map(\.title), ["My Doc", "First", "Second"])
        XCTAssertEqual(plans[1].segments.map(\.text), ["First", "Alpha.", "Beta."])
        XCTAssertEqual(plans[2].segments.map(\.text), ["Second", "item one", "item two"])
        let spoken = plans.map(\.fullText).joined()
        XCTAssertFalse(spoken.contains("hiddenvalue"))
        XCTAssertFalse(spoken.contains("secretkey"))
        for segment in plans.flatMap(\.segments) {
            guard case .web(let section, let offset, let length) = segment.locator else { return XCTFail("not a web locator") }
            XCTAssertEqual(slice(model.sections[section].plainText, .init(location: offset, length: length)), segment.text)
        }
    }

    func testEPUBPlanUsesSpineAndTOCTitles() throws {
        func file(_ name: String, _ text: String) -> ZipEntry { ZipEntry(name: name, data: Data(text.utf8)) }
        let data = try ZipArchive.write([
            file("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"c.opf\"/></rootfiles></container>"),
            file("c.opf", """
            <package><metadata><dc:title>Book</dc:title></metadata><manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
            <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
            <item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
            </manifest><spine><itemref idref="a"/><itemref idref="b"/><itemref idref="c"/></spine></package>
            """),
            file("nav.xhtml", "<html><body><nav epub:type=\"toc\"><ol><li><a href=\"a.xhtml\">Chapter 1</a></li><li><a href=\"c.xhtml\">Chapter 2</a></li></ol></nav></body></html>"),
            file("a.xhtml", "<html><head><title>Skip me</title></head><body><h1>Start</h1>\n<p>A sentence\nwrapped in source.</p></body></html>"),
            file("b.xhtml", "<html><body></body></html>"),
            file("c.xhtml", "<html><body><p>The end.</p></body></html>"),
        ], compressed: false)
        let plans = TTSTextPlanner.planEPUB(try EPUBBook(data: data))
        XCTAssertEqual(plans.map(\.title), ["Chapter 1", "Chapter 2"])
        XCTAssertEqual(plans[0].segments.map(\.text), ["Start", "A sentence wrapped in source."])
        XCTAssertEqual(plans[1].segments.map(\.locator.pageOrSectionIndex), [2])
        XCTAssertEqual(plans.map(\.chapterIndex), [0, 1])
    }

    // MARK: - Start from selection

    func testStartFromExactPhrase() throws {
        let plans = web("First one here. “Smart” quotes — and 🎉 emoji follow.", "Another section talks about turtles.")
        let match = try XCTUnwrap(TTSTextPlanner.findStartSegment(matchingQuote: "turtles", in: plans))
        XCTAssertEqual(match.kind, .exact)
        XCTAssertEqual(match.target.chapterIndex, 1)
        XCTAssertEqual(word(match, in: plans), "turtles")

        let punctuated = try XCTUnwrap(TTSTextPlanner.findStartSegment(matchingQuote: "QUOTES - and\n  🎉", in: plans))
        XCTAssertEqual(punctuated.target.segmentIndex, 1)
        XCTAssertEqual(word(punctuated, in: plans), "quotes")

        let midWord = try XCTUnwrap(TTSTextPlanner.findStartSegment(matchingQuote: "urtles", in: plans))
        XCTAssertEqual(word(midWord, in: plans), "turtles")

        let spanning = try XCTUnwrap(TTSTextPlanner.findStartSegment(matchingQuote: "here. \"Smart\" quotes", in: plans))
        XCTAssertEqual(spanning.target, TTSSeekTarget(chapterIndex: 0, segmentIndex: 0, charOffset: 10))
    }

    func testRepeatedPhraseDisambiguation() throws {
        let plans = web("Red fish swim. The red fish sleeps.", "A red fish jumps high.")
        func find(prefix: String = "", suffix: String = "", page: Int? = nil) throws -> TTSSeekTarget {
            try XCTUnwrap(TTSTextPlanner.findStartSegment(matchingQuote: "red fish", prefix: prefix, suffix: suffix,
                                                          preferredPageOrSection: page, in: plans)).target
        }
        XCTAssertEqual(try find(), TTSSeekTarget(chapterIndex: 0, segmentIndex: 0, charOffset: 0))
        XCTAssertEqual(try find(prefix: "swim. The "), TTSSeekTarget(chapterIndex: 0, segmentIndex: 1, charOffset: 4))
        XCTAssertEqual(try find(suffix: " jumps"), TTSSeekTarget(chapterIndex: 1, segmentIndex: 0, charOffset: 2))
        XCTAssertEqual(try find(prefix: "A ", suffix: " jumps"), TTSSeekTarget(chapterIndex: 1, segmentIndex: 0, charOffset: 2))
        XCTAssertEqual(try find(page: 1), TTSSeekTarget(chapterIndex: 1, segmentIndex: 0, charOffset: 2))
        XCTAssertEqual(try find(suffix: " sleeps", page: 0), TTSSeekTarget(chapterIndex: 0, segmentIndex: 1, charOffset: 4))
    }

    func testSelectionFallbacks() throws {
        let plans = web("Alpha beta gamma.", "Delta epsilon zeta eta theta.")
        let partial = try XCTUnwrap(TTSTextPlanner.findStartSegment(matchingQuote: "epsilon zeta eta missing words", in: plans))
        XCTAssertEqual(partial.kind, .partial)
        XCTAssertEqual(word(partial, in: plans), "epsilon")
        let section = try XCTUnwrap(TTSTextPlanner.findStartSegment(matchingQuote: "nowhere", preferredPageOrSection: 1, in: plans))
        XCTAssertEqual(section.kind, .pageOrSection)
        XCTAssertEqual(section.target, TTSSeekTarget(chapterIndex: 1, segmentIndex: 0, charOffset: 0))
        XCTAssertNil(TTSTextPlanner.findStartSegment(matchingQuote: "nowhere", in: plans))
        XCTAssertNil(TTSTextPlanner.findStartSegment(matchingQuote: "  ", in: plans))
        XCTAssertNil(TTSTextPlanner.findStartSegment(matchingQuote: "Alpha", in: []))
    }

    // MARK: - Live reload

    func testReconcileAfterEdits() throws {
        let edited = web("New opening. Keep this one. Last.")
        let kept = try XCTUnwrap(TTSTextPlanner.reconcile(previousText: "Keep this one.", previousChapter: 0, previousSegment: 0, in: edited))
        XCTAssertEqual([kept.chapterIndex, kept.segmentIndex], [0, 1])
        let deleted = try XCTUnwrap(TTSTextPlanner.reconcile(previousText: "Gone.", previousChapter: 4, previousSegment: 9, in: edited))
        XCTAssertEqual([deleted.chapterIndex, deleted.segmentIndex], [0, 2])
        XCTAssertNil(TTSTextPlanner.reconcile(previousText: "Gone.", previousChapter: 0, previousSegment: 0, in: []))
    }
}
