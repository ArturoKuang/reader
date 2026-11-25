import ReaderCore
import SwiftUI

/// The notes list shared by the inspector and the Highlights and Notes sidebar.
struct AnnotationBrowser: View {
    @ObservedObject var session: ReaderSession
    var onJump: (Annotation) -> Void
    @State private var editing: InlineEdit?
    @State private var vaultSettings = false
    @State private var suppressJump = false
    @State private var conceptCache = ConceptLabelCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search notes and highlights", text: $session.annotationQuery)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Section("Show") {
                        Button("All") { session.annotationFilter = "all" }
                        Button("Notes Only") { session.annotationFilter = "notes" }
                        ForEach(1...6, id: \.self) { color in
                            Button("\(HighlightCallout.name(for: color).capitalized) (\(session.annotations.filter { $0.color == color && $0.highlight != nil }.count))") {
                                session.annotationFilter = "\(color)"
                            }
                        }
                    }
                    Section("Sort") {
                        Button("Page Order") { session.annotationSortRecent = false }
                        Button("Recently Edited") { session.annotationSortRecent = true }
                    }
                } label: {
                    Label(filterTitle, systemImage: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if session.annotationSelection.count > 1 {
                selectionStrip
            }
            if listed.isEmpty {
                Group {
                    if session.annotationQuery.isEmpty && session.annotationFilter == "all" {
                        ContentUnavailableView("No highlights or notes yet", systemImage: "highlighter", description: Text("Select text, then press ⌃⌘1–6 to highlight or ⇧⌘N to add a note."))
                    } else {
                        ContentUnavailableView.search(text: session.annotationQuery)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $session.annotationSelection) {
                    ForEach(AnnotationIndex.grouped(listed)) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                row(item)
                                    .tag(item.id)
                            }
                        }
                    }
                }
                .onChange(of: session.annotationSelection) { _, ids in
                    if let editing = activeEdit, !ids.contains(editing.itemID) { finishEditing(editing.token) }
                    guard !suppressJump, ids.count == 1, let id = ids.first, let item = session.visibleAnnotations.first(where: { $0.id == id }) else { return }
                    onJump(item)
                }
                .onCopyCommand {
                    let chosen = session.visibleAnnotations.filter { session.annotationSelection.contains($0.id) }
                    return [NSItemProvider(object: session.annotationMarkdown(chosen) as NSString)]
                }
                .onExitCommand {
                    if let editing = activeEdit {
                        finishEditing(editing.token)
                    } else {
                        session.annotationSelection = []
                    }
                }
                .contextMenu(forSelectionType: String.self, menu: { ids in
                    self.selectionMenu(ids)
                }, primaryAction: { ids in
                    guard let id = ids.first, let item = session.annotations.first(where: { $0.id == id }) else { return }
                    beginEditing(item)
                })
                .onDeleteCommand {
                    guard activeEdit == nil else { return }
                    session.deleteSelectedAnnotations()
                }
                .onKeyPress(phases: .down) { press in
                    // While a note is being typed, every key belongs to the text editor.
                    guard activeEdit == nil else { return .ignored }
                    if press.key == KeyEquivalent("a"), press.modifiers.contains(.command), !press.modifiers.contains(.shift) {
                        session.annotationSelection = Set(session.visibleAnnotations.map(\.id))
                        return .handled
                    }
                    if press.key == .delete || press.characters == "\u{8}" || press.characters == "\u{7F}" {
                        session.deleteSelectedAnnotations()
                        return .handled
                    }
                    return .ignored
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            vaultFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            suppressJump = true
            if session.annotationSelection.isEmpty, let nearest = AnnotationIndex.nearest(session.annotations, to: session.page) {
                session.annotationSelection = [nearest.id]
            }
            DispatchQueue.main.async { suppressJump = false }
        }
        .onDisappear {
            if let editing { finishEditing(editing.token) }
        }
    }

    /// The row being typed in, unless another editor or an outside change has taken its note.
    private var activeEdit: InlineEdit? {
        guard let editing, session.isNoteEditActive(editing.token) else { return nil }
        return editing
    }

    /// While a row is edited the list keeps its order and keeps that row, whatever the sort and filter say.
    private var listed: [Annotation] {
        var items = session.visibleAnnotations
        guard let editing = activeEdit else { return items }
        if !items.contains(where: { $0.id == editing.itemID }), let item = session.annotation(matching: editing.itemID) {
            items.append(item)
        }
        return AnnotationIndex.holding(items, order: editing.order)
    }

    private var filterTitle: String {
        let sort = session.annotationSortRecent ? "Recent" : "Page"
        if session.annotationFilter == "notes" { return "\(sort) · Notes" }
        if let color = Int(session.annotationFilter) { return "\(sort) · \(HighlightCallout.name(for: color).capitalized)" }
        return "\(sort) · All"
    }

    private func row(_ item: Annotation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: ReaderColor.nsColor(item.color)))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.quote).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                if let editing = activeEdit, editing.itemID == item.id {
                    NoteDraftEditor(initial: item.body) { text in
                        session.queueNoteBody(editing.token, body: text)
                    } finish: {
                        finishEditing(editing.token)
                    }
                    .id(editing.token)
                } else if !item.body.isEmpty {
                    Text(item.body).font(.body)
                }
                HStack {
                    Text(item.page.map { "p. \($0)" } ?? item.section ?? "")
                    if item.ai { Text("AI") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if session.usesVault {
                    let labels = conceptCache.labels(id: item.id, quote: item.quote, concepts: session.concepts, chapter: ChapterFiles.number(in: item.section ?? ""))
                    if !labels.isEmpty {
                        Text(labels.joined(separator: " ")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func beginEditing(_ item: Annotation) {
        if activeEdit?.itemID == item.id { return }
        let order = listed.map(\.id)
        if let editing { finishEditing(editing.token) }
        guard let token = session.beginNoteEdit(id: item.id) else { return }
        editing = InlineEdit(itemID: item.id, token: token, order: order)
    }

    private func finishEditing(_ token: NoteEditToken) {
        if editing?.token == token { editing = nil }
        session.endNoteEdit(token)
    }

    @ViewBuilder private func selectionMenu(_ ids: Set<String>) -> some View {
        if ids.count > 1 {
            Button("Delete \(ids.count) Items") { session.deleteAnnotations(ids: ids) }
        } else if let id = ids.first, let item = session.annotations.first(where: { $0.id == id }) {
            Button("Edit Note") { beginEditing(item) }
            Menu("Color") {
                ForEach(1...6, id: \.self) { color in
                    Button(HighlightCallout.name(for: color).capitalized) {
                        session.recolorAnnotation(id: item.highlight?.id ?? item.id, color: color)
                    }
                }
            }
            Button("Copy Quote") { paste(item.quote) }
            Button("Copy as Markdown") { paste(session.annotationMarkdown([item])) }
            Button("Copy Link") {
                let link = ReaderLink(path: session.bookURL.path, location: item.cfi ?? item.page.map { "page=\($0)" }, id: item.id)
                paste(link.url)
            }
            if session.usesVault {
                Button("Reveal in Obsidian") { session.onRevealInObsidian?(item.id) }
            }
            Button("Remove Highlight & Note") { session.deleteAnnotations(ids: [id]) }
        }
    }

    private var selectionStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text("\(session.annotationSelection.count) selected")
                selectionActions
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.annotationSelection.count) selected")
                selectionActions
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
    }

    private var selectionActions: some View {
        HStack(spacing: 10) {
            Button("Delete") { session.deleteSelectedAnnotations() }
            Menu("Recolor") {
                ForEach(1...6, id: \.self) { color in
                    Button(HighlightCallout.name(for: color).capitalized) {
                        session.recolorAnnotations(ids: session.annotationSelection, color: color)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button("Export") {
                let items = session.visibleAnnotations.filter { session.annotationSelection.contains($0.id) }
                session.exportAnnotations(items)
            }
        }
    }

    private func paste(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var notesCaption: String {
        guard let root = session.vaultRoot, let folder = session.bookFolder else { return "notes" }
        return ObsidianLink.noteFile(
            vaultRoot: root,
            bookFolder: folder,
            notesFolder: session.vaultNotesFolder,
            chapter: ChapterFiles.number(in: session.sectionTitle),
            bookTitle: session.bookURL.deletingPathExtension().lastPathComponent
        )
    }

    @ViewBuilder private var vaultFooter: some View {
        if session.usesVault {
            HStack {
                if session.vaultEnabled {
                    Button(notesCaption) { session.onRevealInObsidian?(nil) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    Text("Obsidian vault found · Not saving here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(session.vaultEnabled ? "Reveal" : "Enable") {
                    if session.vaultEnabled {
                        session.onRevealInObsidian?(nil)
                    } else {
                        session.vaultEnabled = true
                        session.onSaveVaultState?()
                    }
                }
                .buttonStyle(.borderless)
                Button("Settings") { vaultSettings = true }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .popover(isPresented: $vaultSettings) {
                VaultMappingForm(session: session)
            }
        }
    }
}

private struct InlineEdit {
    var itemID: String
    var token: NoteEditToken
    var order: [String]
}

/// The note text lives here, not in the list row, so a later save cannot rebuild the field and drop the caret.
/// Only the user's own changes are sent on, so a stale field never overwrites a newer note.
private struct NoteDraftEditor: View {
    var change: (String) -> Void
    var finish: () -> Void
    @State private var draft: String
    @State private var sent: String
    @FocusState private var focused: Bool

    init(initial: String, change: @escaping (String) -> Void, finish: @escaping () -> Void) {
        self.change = change
        self.finish = finish
        _draft = State(initialValue: initial)
        _sent = State(initialValue: initial)
    }

    var body: some View {
        TextEditor(text: $draft)
            .font(.body)
            .frame(minHeight: 64)
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: draft) { _, text in send(text) }
            .onChange(of: focused) { wasFocused, isFocused in
                if wasFocused && !isFocused { close() }
            }
            .onExitCommand { close() }
    }

    private func send(_ text: String) {
        guard text != sent else { return }
        sent = text
        change(text)
    }

    private func close() {
        send(draft)
        finish()
    }
}

private struct VaultMappingForm: View {
    @ObservedObject var session: ReaderSession
    @State private var notesDraft = ""
    @State private var vocabDraft = ""
    @FocusState private var field: Field?
    private enum Field { case notes, vocab }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Write notes into this vault", isOn: $session.vaultEnabled)
                .onChange(of: session.vaultEnabled) { _, _ in session.onSaveVaultState?() }
            TextField("Notes folder", text: $notesDraft)
                .focused($field, equals: .notes)
                .onSubmit { commitNotes() }
            TextField("Vocabulary file", text: $vocabDraft)
                .focused($field, equals: .vocab)
                .onSubmit { commitVocabulary() }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            notesDraft = session.vaultNotesFolder
            vocabDraft = session.vaultVocabularyFile
        }
        .onChange(of: field) { _, _ in
            commitNotes()
            commitVocabulary()
        }
        .onDisappear {
            commitNotes()
            commitVocabulary()
        }
    }

    private func commitNotes() {
        let next = notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != session.vaultNotesFolder else { return }
        guard Paths.isSafeRelative(next) else {
            notesDraft = session.vaultNotesFolder
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move existing notes?"
        alert.informativeText = "Notes currently live in \(session.vaultNotesFolder)."
        alert.addButton(withTitle: "Move Existing Notes")
        alert.addButton(withTitle: "Start Empty")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            session.onRelocateNotes?(session.vaultNotesFolder, next, true)
        case .alertSecondButtonReturn:
            session.onRelocateNotes?(session.vaultNotesFolder, next, false)
        default:
            notesDraft = session.vaultNotesFolder
        }
    }

    private func commitVocabulary() {
        let next = vocabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != session.vaultVocabularyFile else { return }
        guard next.isEmpty || Paths.isSafeRelative(next) else {
            vocabDraft = session.vaultVocabularyFile
            return
        }
        session.vaultVocabularyFile = next
        session.onSaveVaultState?()
    }
}
