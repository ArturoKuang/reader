import AppKit
import PDFKit
import ReaderCore
import SwiftUI

struct WelcomeView: View {
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reader").font(.largeTitle.weight(.semibold))
            Text("Open a PDF, EPUB, or Markdown file. Drop one here, or press Return on a recent one.")
                .foregroundStyle(.secondary)
            Button("Open…") { NSDocumentController.shared.openDocument(nil) }
            let urls = NSDocumentController.shared.recentDocumentURLs
            if urls.isEmpty {
                ContentUnavailableView("No recent books", systemImage: "books.vertical", description: Text("Open a PDF, EPUB, or Markdown file to start reading."))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                    ForEach(urls.prefix(12), id: \.path) { url in
                        WelcomeTile(url: url, selected: selection == url.path)
                            .onTapGesture { selection = url.path }
                            .focusable()
                            .onKeyPress(keys: [.return], phases: .down) { _ in
                                openRecent(url)
                                return .handled
                            }
                    }
                }
            }
        }
        .onKeyPress(keys: [.return], phases: .down) { _ in
            guard let selection else { return .ignored }
            openRecent(URL(fileURLWithPath: selection))
            return .handled
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                }
            }
            return true
        }
    }

    private func openRecent(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }
}

private struct WelcomeTile: View {
    var url: URL
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                tileImage
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .background(Color(nsColor: .textBackgroundColor))
                if vaultBacked {
                    Image(systemName: "link")
                        .font(.caption)
                        .padding(4)
                }
            }
            Text(url.deletingPathExtension().lastPathComponent).font(.callout).lineLimit(2)
            if let progress {
                Text(progress).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color(nsColor: .quaternaryLabelColor).opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    @ViewBuilder private var tileImage: some View {
        if url.pathExtension.lowercased() == "pdf", let page = PDFDocument(url: url)?.page(at: 0) {
            let image = page.thumbnail(of: NSSize(width: 160, height: 200), for: .mediaBox)
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: BookKind.from(path: url.path) == .markdown ? "doc.richtext" : "book.closed").font(.largeTitle).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 88)
        }
    }

    private var vaultBacked: Bool {
        let index = LibraryIndex.load(from: AppPaths.indexFile, fs: LocalFileSystem())
        return index.documents.contains { $0.bookPath == url.path && $0.vaultBookFolder != nil }
    }

    private var progress: String? {
        let index = LibraryIndex.load(from: AppPaths.indexFile, fs: LocalFileSystem())
        guard let entry = index.documents.first(where: { $0.bookPath == url.path }) else { return nil }
        let statePath = Paths.join(entry.sidecarPath, "state.json")
        guard let data = try? LocalFileSystem().read(statePath), let state = try? JSONDecoder().decode(ViewState.self, from: data), state.page > 1 else { return nil }
        return "Page \(state.page)"
    }
}

struct SidebarView: View {
    @ObservedObject var session: ReaderSession
    @State private var outlineSelection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = session.notice {
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice).font(.caption)
                    HStack {
                        if session.needsReanchor {
                            Button("Re-anchor") { session.reanchor() }
                        }
                        if session.offerMoveTo != nil {
                            Button("Move notes") { session.acceptMove() }
                        }
                        Button("Dismiss") { session.dismissNotice() }
                    }
                }
                .padding(8)
            }
            switch session.sidebar {
            case .hidden, .contactSheet:
                Text(session.sidebar == .contactSheet ? "Contact sheet" : "Sidebar hidden")
                    .font(.caption).foregroundStyle(.secondary).padding()
            case .thumbnails:
                thumbnailList
            case .tableOfContents:
                outlineList
            case .highlightsAndNotes:
                annotationList
            case .bookmarks:
                bookmarkList
            case .searchResults:
                searchList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var thumbnailList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if let document = session.pdfDocument {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        VStack(spacing: 6) {
                            PageThumb(document: document, index: index)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(pageAspect(document, index), contentMode: .fit)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .stroke(session.page == index + 1 ? Color.accentColor : Color.black.opacity(0.12), lineWidth: session.page == index + 1 ? 2 : 1)
                                )
                                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                            Text("\(index + 1)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .onTapGesture { jump(page: index + 1) }
                    }
                } else {
                    ForEach(Array(session.webSectionTitles.enumerated()), id: \.offset) { index, title in
                        Text(title).font(.callout).padding(.vertical, 6)
                            .onTapGesture { jump(page: index + 1) }
                    }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder private var outlineList: some View {
        if session.outline.isEmpty {
            ContentUnavailableView("No table of contents", systemImage: "list.bullet", description: Text("This book has no contents to open."))
        } else {
        List(session.outline, selection: $outlineSelection) { row in
            Text(row.title)
                .font(.callout)
                .padding(.leading, CGFloat(row.depth) * 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listStyle(.sidebar)
        .onChange(of: outlineSelection) { _, id in
            guard let id, let row = session.outline.first(where: { $0.id == id }) else { return }
            if let page = row.page {
                jump(page: page)
            } else if let cfi = row.cfi {
                if let anchor = MarkdownAnchor(value: cfi) { jumpMarkdown(anchor) } else { jumpEPUB(cfi) }
            }
        }
        }
    }

    private var searchList: some View {
        List {
            Section("\(session.searchHits.count) results") {
                ForEach(session.searchHits) { hit in
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.snippet).font(.callout).lineLimit(3)
                Text("\(hit.section) · p. \(hit.page)").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { jump(page: hit.page) }
                }
            }
        }
    }

    private var annotationList: some View {
        AnnotationBrowser(session: session) { item in jumpAnnotation(item) }
            .padding(8)
    }

    private func jumpAnnotation(_ item: Annotation) {
        guard let controller = NSApp.keyWindow?.windowController as? ReaderWindowController else { return }
        controller.reveal(ReadingPosition(page: item.page, cfi: item.cfi, section: item.section, quote: item.quote))
    }

    private var bookmarkList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bookmarks").font(.headline)
                if session.bookmarks.isEmpty {
                    ContentUnavailableView("No bookmarks", systemImage: "bookmark", description: Text("Press ⌘D to bookmark this page."))
                }
                ForEach(session.bookmarks) { bookmark in
                    VStack(alignment: .leading) {
                        Text(bookmark.title).font(.callout)
                        Text(bookmark.page.map { "p. \($0)" } ?? bookmark.section ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        guard let controller = NSApp.keyWindow?.windowController as? ReaderWindowController else { return }
                        controller.reveal(ReadingPosition(page: bookmark.page, cfi: bookmark.cfi, section: bookmark.section))
                    }
                    .contextMenu {
                        Button("Rename") {
                            let alert = NSAlert()
                            alert.messageText = "Rename bookmark"
                            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
                            field.stringValue = bookmark.title
                            alert.accessoryView = field
                            alert.addButton(withTitle: "Rename")
                            alert.addButton(withTitle: "Cancel")
                            if alert.runModal() == .alertFirstButtonReturn {
                                session.renameBookmark(id: bookmark.id, title: field.stringValue)
                            }
                        }
                        Button("Remove") { session.removeBookmark(id: bookmark.id) }
                    }
                }
                Text("Marks").font(.headline).padding(.top, 8)
                Text("Lowercase marks stay in this book. Uppercase marks open whichever book they were set in. Press m, then a key. Press `, then the key to jump.").font(.caption).foregroundStyle(.secondary)
                ForEach(session.marks) { mark in
                    markRow(mark, global: false)
                }
                ForEach(session.globalMarks) { mark in
                    markRow(mark, global: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markRow(_ mark: MarkEntry, global: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(mark.symbol)  \(mark.position.section ?? mark.position.page.map { "p. \($0)" } ?? "")")
                .font(.callout.monospaced())
            Text(global ? (mark.documentTitle ?? "Another book") : "This book")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onTapGesture {
            if global, mark.bookFingerprint != session.fingerprint, let path = mark.bookPath {
                NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, _ in }
            } else if let controller = NSApp.keyWindow?.windowController as? ReaderWindowController {
                controller.reveal(mark.position)
            }
        }
    }

    private func pageAspect(_ document: PDFDocument, _ index: Int) -> CGFloat {
        guard let page = document.page(at: index) else { return 0.72 }
        let box = page.bounds(for: .mediaBox)
        guard box.height > 0 else { return 0.72 }
        return box.width / box.height
    }

    private func jump(page: Int) {
        session.recordJump(from: ReadingPosition(page: session.page, zoom: session.zoom, section: session.sectionTitle), to: ReadingPosition(page: page))
        session.page = page
        session.onPageChange?()
        if let controller = NSApp.keyWindow?.windowController as? ReaderWindowController {
            controller.reveal(ReadingPosition(page: page))
        }
    }

    private func jumpMarkdown(_ anchor: MarkdownAnchor) {
        let target = ReadingPosition(page: anchor.sectionIndex + 1, cfi: anchor.rawValue)
        session.recordJump(from: ReadingPosition(page: session.page, zoom: session.zoom, cfi: session.currentLocation(), section: session.sectionTitle), to: target)
        (NSApp.keyWindow?.windowController as? ReaderWindowController)?.reveal(target)
    }

    private func jumpEPUB(_ href: String) {
        if let index = session.epub?.spine.firstIndex(where: { href.hasPrefix($0.href) || $0.href == href }) {
            jump(page: index + 1)
        }
    }
}

struct PageThumb: NSViewRepresentable {
    var document: PDFDocument
    var index: Int

    func makeNSView(context: Context) -> ThumbView { ThumbView() }
    func updateNSView(_ view: ThumbView, context: Context) {
        view.page = document.page(at: index)
        view.needsDisplay = true
    }
}

final class ThumbView: NSView {
    var page: PDFPage? {
        didSet { cached = nil; needsDisplay = true }
    }
    private var cached: NSImage?
    private static let cache = NSCache<NSString, NSImage>()

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let page else { return }
        let pageBox = page.bounds(for: .mediaBox)
        guard pageBox.width > 0, pageBox.height > 0 else { return }
        let aspect = pageBox.width / pageBox.height
        var target = bounds.insetBy(dx: 4, dy: 4)
        if target.width / max(target.height, 1) > aspect {
            let width = target.height * aspect
            target.origin.x += (target.width - width) / 2
            target.size.width = width
        } else {
            let height = target.width / aspect
            target.origin.y += (target.height - height) / 2
            target.size.height = height
        }
        let key = "\(ObjectIdentifier(page).hashValue)-\(Int(target.width))x\(Int(target.height))" as NSString
        if let cached, cached.size == target.size {
            cached.draw(in: target)
            return
        }
        if let stored = Self.cache.object(forKey: key) {
            cached = stored
            stored.draw(in: target)
            return
        }
        let size = target.size
        let renderedPage = page
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = renderedPage.thumbnail(of: size, for: PDFDisplayBox.mediaBox)
            Self.cache.setObject(image, forKey: key)
            DispatchQueue.main.async {
                self?.cached = image
                self?.needsDisplay = true
            }
        }
    }
}

struct ContactSheetView: View {
    var document: PDFDocument
    @ObservedObject var session: ReaderSession
    var select: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                ForEach(0..<document.pageCount, id: \.self) { index in
                    VStack {
                        PageThumb(document: document, index: index)
                            .aspectRatio(pageAspect(index), contentMode: .fit)
                            .frame(height: 180)
                        Text("\(index + 1)").font(.caption)
                    }
                    .onTapGesture { select(index + 1) }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func pageAspect(_ index: Int) -> CGFloat {
        let box = document.page(at: index)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        return box.width / max(box.height, 1)
    }
}

struct WebContactSheet: View {
    @ObservedObject var session: ReaderSession
    var select: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                ForEach(Array(session.webSectionTitles.enumerated()), id: \.offset) { index, title in
                    Text(title).frame(maxWidth: .infinity, minHeight: 80).padding().background(Color(nsColor: .controlBackgroundColor)).onTapGesture { select(index) }
                }
            }
            .padding(20)
        }
    }
}

struct RightPanelView: View {
    @ObservedObject var session: ReaderSession
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Panel", selection: $session.panelTab) {
                Text("Notes \(session.annotations.count)").tag(PanelTab.notes)
                Text("Words \(session.words.count)").tag(PanelTab.words)
                Text("Ask AI").tag(PanelTab.askAI)
            }
            .pickerStyle(.segmented)
            .padding(8)
            .labelsHidden()
            Divider()
            switch session.panelTab {
            case .notes, .highlights:
                AnnotationBrowser(session: session) { item in jumpAnnotation(item) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .words:
                WordList(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .askAI:
                ask
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func jumpAnnotation(_ item: Annotation) {
        guard let controller = NSApp.keyWindow?.windowController as? ReaderWindowController else { return }
        controller.reveal(ReadingPosition(page: item.page, cfi: item.cfi, section: item.section, quote: item.quote))
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection = session.selection, !selection.text.isEmpty {
                HStack {
                    Text("“\(selection.text)”").font(.callout).italic().lineLimit(3)
                    Spacer()
                    Button { session.selection = nil; session.chat = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
            ControlGroup {
                Button("Explain") { session.withSelection { session.ask(purpose: .explainSimply) } }
                Button("Summarize") { session.withSelection { session.ask(purpose: .summarizeSection) } }
                Button("Define Terms") { session.withSelection { session.ask(purpose: .ask("Define the difficult terms in this passage.")) } }
            }
            if session.tutorAvailable {
                Text("Tutor").font(.caption).foregroundStyle(.secondary)
                ControlGroup {
                    Button("Learn") { session.withSelection { session.askTutor(command: .learn, question: session.question) } }
                    Button("Review") { session.withSelection { session.askTutor(command: .review, question: session.question) } }
                    Button("Wrap") { session.withSelection { session.askTutor(command: .wrap, question: session.question) } }
                }
            }
            if let setup = session.aiSetup {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up AI").font(.headline)
                    Text(setup).font(.callout)
                    Button("Open Settings…") { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if session.chat.isEmpty {
                ContentUnavailableView("Ask about this passage", systemImage: "text.bubble", description: Text("Passages are sent to the chosen provider when you ask."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.chat) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.text).textSelection(.enabled).padding(8).background(line.mine ? Color.accentColor.opacity(0.15) : Color(nsColor: .quaternaryLabelColor).opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 8))
                            if !line.mine, !line.text.isEmpty {
                                HStack {
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(line.text, forType: .string)
                                    }
                                    Button("Save as Note") {
                                        session.answer = line.text
                                        session.saveAnswerAsNote()
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .id(line.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: session.chat.count) { _, _ in
                if let last = session.chat.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $session.question)
                    .font(.body)
                    .focused($questionFocused)
                    .frame(minHeight: 44, maxHeight: 80)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        session.withSelection { session.askCurrentQuestion() }
                        return .handled
                    }
                if session.question.isEmpty {
                    Text("Ask about this passage — Return to send")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: session.focusQuestion) { _, _ in questionFocused = true }
            HStack {
                Picker("Provider", selection: $session.askChoice) {
                    if session.tutorAvailable {
                        Text("Tutor (Claude Code · this book)").tag("tutor")
                    }
                    ForEach(ProviderID.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onAppear {
                    if session.askChoice.isEmpty {
                        session.askChoice = session.tutorAvailable ? "tutor" : session.provider.rawValue
                    }
                }
            if session.askChoice == "tutor" {
                Text(session.claudeSessionID == nil ? "New session" : "Resumed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
                Spacer()
                if session.asking { Button("Stop") { session.stopAsk() } }
            }
        }
    }
}

struct WordList: View {
    @ObservedObject var session: ReaderSession
    @State private var query = ""
    @State private var sort = "recent"
    @State private var filter = "all"

    private var vocabularyCaption: String {
        guard session.vaultEnabled, let root = session.vaultRoot, let folder = session.bookFolder else {
            return "Obsidian vault found · Not saving here"
        }
        let relative = session.vaultVocabularyFile.isEmpty ? "learner/vocabulary.md" : session.vaultVocabularyFile
        let absolute = relative.hasPrefix("/") ? relative : Paths.join(folder, relative)
        return ObsidianLink.displayPath(vaultRoot: root, absolute: absolute)
    }

    var body: some View {
        let rows = ordered
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search words", text: $query)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Section("Sort") {
                        Button("Recent") { sort = "recent" }
                        Button("A–Z") { sort = "alpha" }
                        Button("Page") { sort = "page" }
                    }
                    Section("Filter") {
                        Button("All") { filter = "all" }
                        Button("Learning") { filter = "learning" }
                        Button("Learned") { filter = "learned" }
                    }
                } label: {
                    Label(wordMenuTitle, systemImage: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if rows.isEmpty {
                ContentUnavailableView("No words yet", systemImage: "character.book.closed", description: Text("Look up a word with ⌃⌘D or Force Click. It lands here with its sentence."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(rows) { word in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.word).font(.body.weight(.semibold))
                            Text(word.definition).font(.callout).lineLimit(2)
                            if let sentence = word.lookups.first?.sentence {
                                Text(sentence).font(.caption).lineLimit(1)
                            }
                            Text(word.lookups.first?.page.map { "p. \($0)" } ?? word.lookups.first?.section ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard let lookup = word.lookups.first, let controller = NSApp.keyWindow?.windowController as? ReaderWindowController else { return }
                            controller.reveal(ReadingPosition(page: lookup.page, cfi: lookup.cfi, section: lookup.section, quote: lookup.sentence))
                        }
                        .contextMenu {
                            Button("Copy") { copy(word.word) }
                            Button("Copy with Sentence") { copy("\(word.word) — \(word.lookups.first?.sentence ?? "")") }
                            Button(word.learned ? "Mark Learning" : "Mark Learned") { session.setLearned(id: word.id, learned: !word.learned) }
                            Button("Remove") { session.deleteWord(id: word.id) }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { rows[$0].id }.forEach { session.deleteWord(id: $0) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if session.usesVault {
                Text(vocabularyCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var wordMenuTitle: String {
        let sortName = sort == "alpha" ? "A–Z" : (sort == "page" ? "Page" : "Recent")
        let filterName = filter == "learned" ? "Learned" : (filter == "learning" ? "Learning" : "All")
        return "\(sortName) · \(filterName)"
    }

    private var ordered: [WordEntry] {
        var rows = session.words.filter { word in
            (query.isEmpty || word.word.localizedCaseInsensitiveContains(query) || word.definition.localizedCaseInsensitiveContains(query))
                && (filter == "all" || (filter == "learned" ? word.learned : !word.learned))
        }
        switch sort {
        case "alpha": rows.sort { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        case "page": rows.sort { ($0.lookups.first?.page ?? Int.max) < ($1.lookups.first?.page ?? Int.max) }
        default: break
        }
        return rows
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct LookupCard: View {
    @ObservedObject var session: ReaderSession
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lookup = session.lookup {
                Text(lookup.word).font(.title2.weight(.semibold))
                if let times = session.words.first(where: { $0.word.caseInsensitiveCompare(lookup.word) == .orderedSame })?.count, times > 1 {
                    Text("Looked up \(times)×").font(.caption).foregroundStyle(.secondary)
                }
                Text("Dictionary").font(.caption).foregroundStyle(.secondary)
                Text(lookup.definition)
                Text(lookup.busy ? "Explaining…" : "In this passage").font(.caption).foregroundStyle(.secondary)
                Text(lookup.explanation.isEmpty ? " " : lookup.explanation)
                if lookup.explanation.contains("Settings") {
                    Button("Open Settings…") { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
                        .buttonStyle(.borderless)
                }
                Text("“\(lookup.sentence)” · \(lookup.location)").font(.caption).italic()
                HStack {
                    Text("Saved to Words").font(.caption).foregroundStyle(.secondary)
                    Button("Undo") { session.undoLookup(); dismiss() }.buttonStyle(.borderless)
                    Spacer()
                    Button("Open in Dictionary") {
                        if let url = URL(string: "dict://\(lookup.word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? lookup.word)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

struct SettingsView: View {
    @State private var settings = SettingsStore.load()
    @State private var openAIKey = KeychainStore.load(account: "openai") ?? ""
    @State private var anthropicKey = KeychainStore.load(account: "anthropic") ?? ""
    @State private var keyStatus = ""
    @State private var detectingCLIs = false
    @State private var voiceGroups: [TTSVoiceCatalog.Group] = TTSVoiceCatalog.groups()
    @State private var kokoroStatus: KokoroModelStatus = KokoroEngineService.isModelCachedOnDisk() ? .cached : .notDownloaded
    @State private var openInspector = UserDefaults.standard.object(forKey: "reader.openInspector") as? Bool ?? true
    @FocusState private var keyField: String?

    var body: some View {
        TabView {
        Form {
            Section("General") {
                Toggle("Show the annotation bar when selecting text", isOn: $settings.showSelectionBar)
                Toggle("Open the inspector for notes and lookups", isOn: $openInspector)
                    .onChange(of: openInspector) { _, value in
                        UserDefaults.standard.set(value, forKey: "reader.openInspector")
                    }
            }
            readAloudSection
        }
        .formStyle(.grouped)
        .onAppear {
            voiceGroups = TTSVoiceCatalog.groups(including: settings.ttsVoiceIdentifier)
            Task { kokoroStatus = await KokoroEngineService.shared.currentStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kokoroStatusDidChange)) { _ in
            Task { kokoroStatus = await KokoroEngineService.shared.currentStatus() }
        }
        // The player saves speed and voice too; keep this copy from overwriting them.
        .onChange(of: settings.ttsRateMultiplier) { _, newValue in
            let saved = SettingsStore.load()
            guard abs(saved.ttsRateMultiplier - newValue) > 0.0001 else { return }
            SettingsStore.save(settings)
            NotificationCenter.default.post(name: .ttsSettingsDidChange, object: nil)
        }
        .onChange(of: settings.ttsVoiceIdentifier) { _, newValue in
            let saved = SettingsStore.load()
            guard saved.ttsVoiceIdentifier != newValue else { return }
            SettingsStore.save(settings)
            NotificationCenter.default.post(name: .ttsSettingsDidChange, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsSettingsDidChange)) { _ in
            let saved = SettingsStore.load()
            settings.ttsRateMultiplier = saved.ttsRateMultiplier
            settings.ttsVoiceIdentifier = saved.ttsVoiceIdentifier
        }
        .tabItem { Text("General") }
        Form {
            Section("Default") {
                Picker("Provider", selection: $settings.defaultProvider) {
                    ForEach(ProviderID.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("ChatGPT is the default for Ask AI and for word explanations.").font(.caption).foregroundStyle(.secondary)
            }
            Section("API keys") {
                SecureField("OpenAI API key", text: $openAIKey)
                    .focused($keyField, equals: "openai")
                    .onSubmit { storeKey(account: "openai", value: openAIKey) }
                TextField("OpenAI model", text: $settings.openAIModel)
                SecureField("Anthropic API key", text: $anthropicKey)
                    .focused($keyField, equals: "anthropic")
                    .onSubmit { storeKey(account: "anthropic", value: anthropicKey) }
                TextField("Anthropic model", text: $settings.anthropicModel)
                if !keyStatus.isEmpty {
                    Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Keys are stored in the login keychain under \(KeychainStore.service). They are not written into settings.json.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal providers") {
                TextField("claude path", text: Binding(get: { settings.claudeCLIPath ?? "" }, set: { settings.claudeCLIPath = $0.isEmpty ? nil : $0 }))
                TextField("codex path", text: Binding(get: { settings.codexCLIPath ?? "" }, set: { settings.codexCLIPath = $0.isEmpty ? nil : $0 }))
                Button("Detect installed CLIs") {
                    detectingCLIs = true
                    Task.detached {
                        let claude = CLILocator.locate("claude")
                        let codex = CLILocator.locate("codex")
                        await MainActor.run {
                            settings.claudeCLIPath = claude
                            settings.codexCLIPath = codex
                            detectingCLIs = false
                        }
                    }
                }
                if detectingCLIs { ProgressView().controlSize(.small) }
                HStack {
                    Circle().fill(aiReady ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(aiReady ? "Ready" : "Not configured").font(.caption)
                    Button("Test") { testAI() }
                }
                Text("A saved claude path overrides detection. Otherwise Reader looks in ~/.local/bin, Homebrew, /usr/local/bin, then `zsh -lc 'command -v claude'`.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Look up") {
                Toggle("Use the default provider for word explanations", isOn: $settings.lookupUsesDefault)
                if !settings.lookupUsesDefault {
                    Picker("Look up provider", selection: $settings.lookupProvider) {
                        ForEach(ProviderID.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Toggle("Suggested notes", isOn: $settings.suggestedNotes)
                Text("Suggested notes stay off until you turn them on. Reader does not write a suggestion unless you ask.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .tabItem { Text("AI") }
        VaultLibrarySettings()
            .tabItem { Text("Vault") }
        ShortcutList()
            .tabItem { Text("Shortcuts") }
        }
        .onChange(of: settings) { _, newValue in
            SettingsStore.save(newValue)
        }
        .onChange(of: keyField) { old, _ in
            guard let old else { return }
            storeKey(account: old, value: old == "openai" ? openAIKey : anthropicKey)
        }
        .onDisappear {
            storeKey(account: "openai", value: openAIKey)
            storeKey(account: "anthropic", value: anthropicKey)
        }
        .padding()
        .frame(width: 500, height: 560)
    }

    private var aiReady: Bool {
        if settings.defaultProvider == .openai { return !openAIKey.isEmpty }
        if settings.defaultProvider == .anthropic { return !anthropicKey.isEmpty }
        let path = settings.defaultProvider == .claudeCLI ? settings.claudeCLIPath : settings.codexCLIPath
        return path.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
    }

    private func testAI() {
        let provider = settings.defaultProvider
        if provider == .openai, openAIKey.isEmpty {
            keyStatus = AIError.missingKey(provider: "ChatGPT").userMessage
            return
        }
        if provider == .anthropic, anthropicKey.isEmpty {
            keyStatus = AIError.missingKey(provider: "Claude").userMessage
            return
        }
        keyStatus = "Testing…"
        let current = settings
        let openAI = openAIKey
        let anthropic = anthropicKey
        Task {
            let router = AIRouter(settings: current, openAIKey: openAI, anthropicKey: anthropic, transport: URLSessionTransport(), runner: ProcessCommandRunner())
            do {
                let book = BookText(title: "Test", pages: [BookPage(marker: "p. 1", text: "Hello.", page: 1)])
                _ = try await router.answer(book: book, focus: nil, purpose: .ask("Reply with one word."), provider: provider, cliDirectory: NSTemporaryDirectory(), fs: LocalFileSystem())
                keyStatus = "Ready"
            } catch {
                keyStatus = (error as? AIError)?.userMessage ?? (error as? ReaderFailure)?.message ?? error.localizedDescription
            }
        }
    }


    private var selectedKokoroVoiceID: Binding<String> {
        Binding(
            get: { KokoroVoiceCatalog.resolve(settings.ttsVoiceIdentifier).id },
            set: { settings.ttsVoiceIdentifier = $0 }
        )
    }

    private var readAloudSection: some View {
        Section("Read Aloud (Kokoro-82M)") {
            Picker("Speed", selection: $settings.ttsRateMultiplier) {
                ForEach(TTSSpeedPreset.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Voice", selection: selectedKokoroVoiceID) {
                ForEach(voiceGroups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.voices, id: \.identifier) { Text($0.label).tag($0.identifier) }
                    }
                }
            }
            HStack {
                Text("Voice Model")
                Spacer()
                Text(kokoroStatus.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                kokoroActionButton
            }
        }
    }

    @ViewBuilder
    private var kokoroActionButton: some View {
        switch kokoroStatus {
        case .notDownloaded:
            Button("Download") { triggerKokoroDownload() }
                .controlSize(.small)
        case .failed:
            Button("Retry") { triggerKokoroDownload() }
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func triggerKokoroDownload() {
        let voiceID = KokoroVoiceCatalog.resolve(settings.ttsVoiceIdentifier).id
        Task { _ = try? await KokoroEngineService.shared.ensureReady(voiceID: voiceID) }
    }

    private func storeKey(account: String, value: String) {
        if value.isEmpty {
            KeychainStore.delete(account: account)
            keyStatus = "Removed from Keychain"
        } else {
            KeychainStore.save(account: account, secret: value)
            keyStatus = "Saved in Keychain"
        }
    }
}

struct VaultLibrarySettings: View {
    private var books: [LibraryEntry] {
        LibraryIndex.load(from: AppPaths.indexFile, fs: LocalFileSystem()).documents.filter { entry in
            entry.vaultBookFolder != nil || FileManager.default.fileExists(atPath: Paths.join(entry.sidecarPath, ".reader-state.json"))
        }
    }

    var body: some View {
        if books.isEmpty {
            ContentUnavailableView("No vault books", systemImage: "link", description: Text("Link a book from File, or open one that already lives in a vault."))
        } else {
            List(books, id: \.bookPath) { entry in
                VaultBookRow(entry: entry)
            }
        }
    }
}

private struct VaultBookRow: View {
    var entry: LibraryEntry
    @State private var enabled = true
    private var folder: String { entry.vaultBookFolder ?? entry.sidecarPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
            Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Toggle("Save notes here", isOn: $enabled)
                .onChange(of: enabled) { _, value in
                    let fs = LocalFileSystem()
                    var settings = VaultBookSettings.load(bookFolder: folder, fs: fs)
                    settings.enabled = value
                    try? settings.save(bookFolder: folder, fs: fs)
                }
            Button("Reveal") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) }
                .buttonStyle(.borderless)
        }
        .onAppear {
            enabled = VaultBookSettings.load(bookFolder: folder, fs: LocalFileSystem()).enabled
        }
    }
}

struct ShortcutList: View {
    var body: some View {
        List(ShortcutCatalog.current()) { row in
            HStack {
                Text(row.title)
                Spacer()
                Text(row.keys).foregroundStyle(.secondary)
            }
        }
    }
}

struct WordsBrowser: View {
    var books: [LibraryEntry]
    @State private var query = ""
    @State private var sort = "page"
    @State private var book = "All"
    @State private var selected: String?

    var body: some View {
        let rows = gathered.filter { row in
            (book == "All" || row.book == book) && (query.isEmpty || row.word.localizedCaseInsensitiveContains(query) || row.definition.localizedCaseInsensitiveContains(query))
        }
        VStack {
        Picker("Book", selection: $book) {
            Text("All books").tag("All")
            ForEach(Array(Set(books.map(\.title))).sorted(), id: \.self) { title in
                Text(title).tag(title)
            }
        }
        HSplitView {
            List(rows, id: \.word, selection: $selected) { row in
                VStack(alignment: .leading) {
                    Text(row.word).font(.body.weight(.semibold))
                    Text(row.definition).font(.caption).lineLimit(2)
                    Text("\(row.book) · \(row.location)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 280)
            if let row = rows.first(where: { $0.word == selected }) ?? rows.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.word).font(.largeTitle)
                    Text(row.definition)
                    Text("“\(row.sentence)”").italic()
                    Text("\(row.book) · \(row.location)").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(rows.count) words").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Export all books’ words…") { (NSApp.delegate as? AppDelegate)?.exportAllWords(nil) }
            }
            .padding(8)
        }
        }
    }

    private var gathered: [WordRow] {
        books.flatMap { entry -> [WordRow] in
            guard let package = try? SidecarPackage.read(from: entry.sidecarPath, fs: LocalFileSystem()) else { return [] }
            return package.words.words.map { word in
                let lookup = word.lookups.first
                return WordRow(word: word.word, definition: word.definition, sentence: lookup?.sentence ?? "", book: entry.title, location: lookup?.page.map { "p. \($0)" } ?? "", page: lookup?.page ?? Int.max)
            }
        }.sorted { sort == "az" ? $0.word < $1.word : $0.page < $1.page }
    }
}

private struct WordRow {
    var word: String
    var definition: String
    var sentence: String
    var book: String
    var location: String
    var page: Int
}

struct ShortcutsView: View {
    @State private var query = ""

    var body: some View {
        let rows = ShortcutCatalog.current().filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.keys.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Viewing shortcuts match Preview. Notes, words, and Ask AI use the Reader shortcuts. ⌘1–⌘3 stay with Continuous Scroll, Single Page, and Two Pages, so the side panel uses ⌃1–⌃4.").font(.callout).foregroundStyle(.secondary)
            TextField("Search shortcuts", text: $query).textFieldStyle(.roundedBorder)
            List(rows) { row in
                HStack {
                    Text(row.title)
                    Spacer()
                    Text(row.keys).foregroundStyle(.secondary).monospaced()
                }
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 560)
    }
}

extension ReaderSession {
    /// One title per EPUB spine item or Markdown section.
    var webSectionTitles: [String] {
        markdown?.sections.map(\.title) ?? epub?.spine.map(\.title) ?? []
    }
}
