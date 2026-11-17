import AppKit
import PDFKit
import ReaderCore
import SwiftUI

struct WelcomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reader").font(.largeTitle.weight(.semibold))
            Text("Open a PDF or EPUB. Notes, words, and highlights stay in a .reader package next to the book.")
                .foregroundStyle(.secondary)
            Button("Open…") { NSDocumentController.shared.openDocument(nil) }
                .keyboardShortcut("o")
            if !NSDocumentController.shared.recentDocumentURLs.isEmpty {
                Text("Recent").font(.headline)
                ForEach(NSDocumentController.shared.recentDocumentURLs.prefix(6), id: \.path) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SidebarView: View {
    @ObservedObject var session: ReaderSession

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
                                .aspectRatio(0.72, contentMode: .fit)
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
                    ForEach(Array((session.epub?.spine ?? []).enumerated()), id: \.offset) { index, item in
                        Text(item.title).font(.callout).padding(.vertical, 6)
                            .onTapGesture { jump(page: index + 1) }
                    }
                }
            }
            .padding(10)
        }
    }

    private var outlineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if session.outline.isEmpty {
                    Text("This document has no table of contents.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session.outline) { row in
                    Text(row.title)
                        .font(.callout)
                        .padding(.leading, CGFloat(row.depth) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { if let page = row.page { jump(page: page) } else if let cfi = row.cfi { jumpEPUB(cfi) } }
                }
            }
            .padding(10)
        }
    }

    private var annotationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(session.highlights) { highlight in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: ReaderColor.nsColor(highlight.color))).frame(width: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(highlight.page.map { "p. \($0)" } ?? highlight.section ?? "").font(.caption).foregroundStyle(.secondary)
                            Text(highlight.quote).font(.callout).lineLimit(4)
                        }
                    }
                    .onTapGesture { if let page = highlight.page { jump(page: page) } }
                    .contextMenu {
                        Button("Remove Highlight") { session.deleteHighlight(id: highlight.id) }
                    }
                }
                ForEach(session.notes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.page.map { "Note · p. \($0)" } ?? "Note").font(.caption).foregroundStyle(.secondary)
                        Text(note.body.isEmpty ? note.quote : note.body).font(.callout).lineLimit(4)
                    }
                    .onTapGesture { if let page = note.page { jump(page: page) } }
                }
                if session.highlights.isEmpty && session.notes.isEmpty {
                    Text("No highlights or notes yet.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
    }

    private var bookmarkList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bookmarks").font(.headline)
                if session.bookmarks.isEmpty {
                    Text("Press ⌘D to bookmark this page.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session.bookmarks) { bookmark in
                    VStack(alignment: .leading) {
                        Text(bookmark.title).font(.callout)
                        Text(bookmark.page.map { "p. \($0)" } ?? bookmark.section ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    .onTapGesture { if let page = bookmark.page { jump(page: page) } }
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
            } else if let page = mark.position.page {
                jump(page: page)
            }
        }
    }

    private func jump(page: Int) {
        session.recordJump(from: ReadingPosition(page: session.page, zoom: session.zoom, section: session.sectionTitle), to: ReadingPosition(page: page))
        session.page = page
        session.onPageChange?()
        if let controller = NSApp.keyWindow?.windowController as? ReaderWindowController {
            controller.reveal(ReadingPosition(page: page))
        }
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
    var page: PDFPage?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let page else { return }
        let image = page.thumbnail(of: bounds.insetBy(dx: 4, dy: 4).size, for: .mediaBox)
        image.draw(in: bounds.insetBy(dx: 4, dy: 4))
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
                        PageThumb(document: document, index: index).frame(height: 180)
                        Text("\(index + 1)").font(.caption)
                    }
                    .onTapGesture { select(index + 1) }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct EPUBContactSheet: View {
    @ObservedObject var session: ReaderSession
    var select: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                ForEach(Array((session.epub?.spine ?? []).enumerated()), id: \.offset) { index, item in
                    Text(item.title).frame(maxWidth: .infinity, minHeight: 80).padding().background(Color(nsColor: .controlBackgroundColor)).onTapGesture { select(index) }
                }
            }
            .padding(20)
        }
    }
}

struct RightPanelView: View {
    @ObservedObject var session: ReaderSession
    @FocusState private var noteFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Panel", selection: $session.panelTab) {
                Text("Notes \(session.notes.count)").tag(PanelTab.notes)
                Text("Words \(session.words.count)").tag(PanelTab.words)
                Text("Highlights \(session.highlights.count)").tag(PanelTab.highlights)
                Text("Ask AI").tag(PanelTab.askAI)
            }
            .pickerStyle(.segmented)
            .padding(8)
            .labelsHidden()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch session.panelTab {
                    case .notes: notes
                    case .words: words
                    case .highlights: highlights
                    case .askAI: ask
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var notes: some View {
        Group {
            if session.notes.isEmpty { Text("Select a passage and press ⇧⌘N.").foregroundStyle(.secondary) }
            ForEach(session.notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.page.map { "p. \($0)" } ?? note.section ?? "").font(.caption).foregroundStyle(.secondary)
                    Text("“\(note.quote)”").font(.callout).italic().foregroundStyle(.secondary)
                    Text(note.body).font(.body)
                    if note.ai { Text("AI suggestion").font(.caption) }
                }
                .onTapGesture { session.toggleNote(note.id) }
            }
            if session.usesVault {
                vaultMapping
                conceptComposer
            }
        }
    }

    private var vaultMapping: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Write notes into this vault", isOn: $session.vaultEnabled)
                .onChange(of: session.vaultEnabled) { _, _ in session.onSaveVaultState?() }
            TextField("Notes folder", text: $session.vaultNotesFolder)
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.onSaveVaultState?() }
            TextField("Vocabulary file", text: $session.vaultVocabularyFile)
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.onSaveVaultState?() }
        }
    }

    private var conceptComposer: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Write a note. Type [[ for a concept", text: $session.noteDraft)
                .textFieldStyle(.roundedBorder)
                .focused($noteFieldFocused)
                .onSubmit { session.commitNoteDraft() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        session.commitNoteDraft()
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: noteFieldFocused) { _, focused in
                    if !focused {
                        DispatchQueue.main.async { session.commitNoteDraft() }
                    }
                }
            if let query = conceptQuery(session.noteDraft) {
                ForEach(Array(ConceptsFile.autocomplete(prefix: query, concepts: session.concepts).prefix(6))) { concept in
                    Button(concept.wiki) {
                        session.onInsertConcept?(concept)
                        if let range = session.noteDraft.range(of: "[[", options: .backwards) {
                            session.noteDraft.replaceSubrange(range.lowerBound..<session.noteDraft.endIndex, with: concept.wiki)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(conceptHelp(concept))
                }
            }
        }
    }

    private func conceptQuery(_ text: String) -> String? {
        guard let range = text.range(of: "[[", options: .backwards) else { return nil }
        let rest = String(text[range.upperBound...])
        if rest.contains("]]") { return nil }
        return rest
    }

    private var words: some View {
        Group {
            if session.words.isEmpty { Text("Looked-up words from this book land here.").foregroundStyle(.secondary) }
            ForEach(session.words) { word in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(word.word).font(.body.weight(.semibold))
                        Spacer()
                        Text(word.count > 1 ? "looked up \(word.count)×" : "once").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(word.definition).font(.callout)
                    if let sentence = word.lookups.first?.sentence {
                        Text("“\(sentence)”").font(.caption).italic()
                    }
                    Button(word.learned ? "Learned" : "Mark as learned") { session.setLearned(id: word.id, learned: !word.learned) }
                        .font(.caption)
                }
            }
        }
    }

    private var highlights: some View {
        Group {
            if session.highlights.isEmpty {
                Text("Six colors, numbered 1–6. ⌃⌘1 through ⌃⌘6. Select a row and press Delete to remove it.").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(session.highlights) { highlight in
                        HStack(alignment: .top) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: ReaderColor.nsColor(highlight.color))).frame(width: 4)
                            VStack(alignment: .leading) {
                                Text("Color \(highlight.color) · \(highlight.page.map { "p. \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                                Text(highlight.quote).font(.callout)
                            }
                        }
                        .contextMenu {
                            Button("Remove Highlight") { session.deleteHighlight(id: highlight.id) }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { session.highlights[$0].id }
                        ids.forEach { session.deleteHighlight(id: $0) }
                    }
                }
                .frame(minHeight: 220)
            }
        }
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection = session.selection {
                Text("“\(selection.text)”").font(.callout).italic().padding(.leading, 8).overlay(alignment: .leading) { Rectangle().frame(width: 3).foregroundStyle(.secondary) }
            }
            Picker("Provider", selection: $session.provider) {
                ForEach(ProviderID.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextField("Ask about the selection", text: $session.question)
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.withSelection { session.askCurrentQuestion() } }
            HStack {
                Button(session.asking ? "Asking…" : "Ask") { session.withSelection { session.askCurrentQuestion() } }.disabled(session.asking)
                Button("Stop") { session.stopAsk() }.disabled(!session.asking)
            }
            if session.tutorAvailable {
                HStack {
                    Button("Learn") { session.withSelection { session.askTutor(command: .learn, question: session.question) } }
                    Button("Review") { session.withSelection { session.askTutor(command: .review, question: session.question) } }
                    Button("Wrap") { session.withSelection { session.askTutor(command: .wrap, question: session.question) } }
                }
                ForEach(Array(session.tutorLines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).textSelection(.enabled)
                }
                if !session.concepts.isEmpty {
                    Text("Concepts in this passage").font(.caption).foregroundStyle(.secondary)
                    ForEach(ConceptsFile.suggested(passage: session.selection?.text ?? "", concepts: session.concepts, chapter: ChapterFiles.number(in: session.selection?.section ?? session.sectionTitle))) { concept in
                        Text(concept.wiki).font(.caption).help(conceptHelp(concept))
                    }
                }
            }
            if !session.answer.isEmpty {
                Text(session.answer).textSelection(.enabled)
                Text(session.answerLabel).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save as note") { session.saveAnswerAsNote() }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.answer, forType: .string)
                    }
                }
            }
            Text("Questions are sent as soon as you ask. Nothing is saved unless you choose Save as note.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func conceptHelp(_ concept: Concept) -> String {
        var lines: [String] = []
        if let claim = concept.claim { lines.append("Claim: \(claim)") }
        if let trap = concept.trap { lines.append("Trap: \(trap)") }
        return lines.joined(separator: "\n")
    }
}

struct LookupCard: View {
    @ObservedObject var session: ReaderSession
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lookup = session.lookup {
                Text(lookup.word).font(.title2.weight(.semibold))
                Text("Dictionary").font(.caption).foregroundStyle(.secondary)
                Text(lookup.definition)
                Text(lookup.busy ? "Explaining…" : "In this passage").font(.caption).foregroundStyle(.secondary)
                Text(lookup.explanation.isEmpty ? " " : lookup.explanation)
                Text("Saved automatically to words.md").font(.caption)
                Text("“\(lookup.sentence)” · \(lookup.location)").font(.caption).italic()
                Text(lookup.providerLabel).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Undo save") { session.undoLookup(); dismiss() }
                    Button("Close") { dismiss() }
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
    @State private var saved = false

    var body: some View {
        Form {
            Section("Default") {
                Picker("Provider", selection: $settings.defaultProvider) {
                    ForEach(ProviderID.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("ChatGPT is the default for Ask AI and for word explanations.").font(.caption).foregroundStyle(.secondary)
            }
            Section("API keys") {
                SecureField("OpenAI API key", text: $openAIKey)
                TextField("OpenAI model", text: $settings.openAIModel)
                SecureField("Anthropic API key", text: $anthropicKey)
                TextField("Anthropic model", text: $settings.anthropicModel)
                Text("Keys are stored in the login keychain under \(KeychainStore.service). They are not written into settings.json.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal providers") {
                TextField("claude path", text: Binding(get: { settings.claudeCLIPath ?? "" }, set: { settings.claudeCLIPath = $0.isEmpty ? nil : $0 }))
                TextField("codex path", text: Binding(get: { settings.codexCLIPath ?? "" }, set: { settings.codexCLIPath = $0.isEmpty ? nil : $0 }))
                Button("Detect installed CLIs") {
                    settings.claudeCLIPath = CLILocator.locate("claude")
                    settings.codexCLIPath = CLILocator.locate("codex")
                }
                Text("Reader runs `claude --print` and `codex exec` with read-only tools. Sign in with those tools themselves; Reader does not ask before sending.").font(.caption).foregroundStyle(.secondary)
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
            Button(saved ? "Saved" : "Save") {
                if !openAIKey.isEmpty { KeychainStore.save(account: "openai", secret: openAIKey) }
                if !anthropicKey.isEmpty { KeychainStore.save(account: "anthropic", secret: anthropicKey) }
                SettingsStore.save(settings)
                saved = true
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 560)
    }
}

struct WordsBrowser: View {
    var books: [LibraryEntry]
    @State private var query = ""
    @State private var sort = "page"
    @State private var selected: String?

    var body: some View {
        let rows = gathered.filter { query.isEmpty || $0.word.localizedCaseInsensitiveContains(query) || $0.definition.localizedCaseInsensitiveContains(query) }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Viewing shortcuts match Preview. Notes, words, and Ask AI use the Reader shortcuts. ⌘1–⌘3 stay with Continuous Scroll, Single Page, and Two Pages, so the side panel uses ⌃1–⌃4.").font(.callout).foregroundStyle(.secondary)
            List(ShortcutCatalog.rows) { row in
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
