import ReaderCore
import SwiftUI

/// The notes list shared by the inspector and the Highlights and Notes sidebar.
struct AnnotationBrowser: View {
    @ObservedObject var session: ReaderSession
    var onJump: (Annotation) -> Void
    @State private var editing: String?
    @State private var drafts: [String: String] = [:]
    @State private var vaultSettings = false
    @State private var suppressJump = false
    @State private var conceptCache = ConceptLabelCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search notes…", text: $session.annotationQuery)
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
                .help("Filter and sort highlights and notes")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if session.annotationSelection.count > 1 {
                selectionStrip
            }
            if session.visibleAnnotations.isEmpty {
                Group {
                    if session.annotationQuery.isEmpty && session.annotationFilter == "all" {
                        VStack(spacing: 8) {
                            Image(systemName: "highlighter")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("No highlights or notes yet")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Select text, then press ⌃⌘1–6 to highlight or ⇧⌘N to add a note.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                    } else {
                        ContentUnavailableView.search(text: session.annotationQuery)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $session.annotationSelection) {
                    ForEach(AnnotationIndex.grouped(session.visibleAnnotations)) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                row(item)
                                    .tag(item.id)
                            }
                        }
                    }
                }
                .onChange(of: session.annotationSelection) { _, ids in
                    guard !suppressJump, ids.count == 1, let id = ids.first, let item = session.visibleAnnotations.first(where: { $0.id == id }) else { return }
                    if NSEvent.modifierFlags.contains(.option) {
                        ReaderWindowController.controller(for: session)?.openInPane(item)
                        return
                    }
                    onJump(item)
                }
                .onCopyCommand {
                    let chosen = session.visibleAnnotations.filter { session.annotationSelection.contains($0.id) }
                    return [NSItemProvider(object: session.annotationMarkdown(chosen) as NSString)]
                }
                .onExitCommand {
                    if let editing {
                        self.editing = nil
                        session.endNoteEdit(id: editing)
                    } else {
                        session.annotationSelection = []
                    }
                }
                .contextMenu(forSelectionType: String.self, menu: { ids in
                    self.selectionMenu(ids)
                }, primaryAction: { ids in
                    guard let id = ids.first, let item = session.annotations.first(where: { $0.id == id }) else { return }
                    if NSEvent.modifierFlags.contains(.option) { return }
                    beginEditing(item)
                })
                .onDeleteCommand { session.deleteSelectedAnnotations() }
                .onKeyPress(phases: .down) { press in
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
                if isEditing(item) {
                    let key = noteKey(item)
                    NoteDraftEditor(initial: drafts[key] ?? item.body) { text in
                        drafts[key] = text
                        session.queueNoteBody(id: key, body: text)
                    } finish: {
                        drafts[key] = nil
                        editing = nil
                        session.endNoteEdit(id: key)
                    }
                    .id(key)
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

    private func noteKey(_ item: Annotation) -> String {
        item.note?.id ?? item.highlight?.noteID ?? item.id
    }

    private func isEditing(_ item: Annotation) -> Bool {
        guard let editing else { return false }
        return editing == item.id || editing == item.note?.id || editing == item.highlight?.noteID
    }

    private func beginEditing(_ item: Annotation) {
        let key = noteKey(item)
        editing = key
        session.beginNoteEdit(id: key)
    }

    @ViewBuilder private func selectionMenu(_ ids: Set<String>) -> some View {
        if ids.count > 1 {
            Button("Delete \(ids.count) Items") { session.deleteAnnotations(ids: ids) }
        } else if let id = ids.first, let item = session.annotations.first(where: { $0.id == id }) {
            Button("Edit Note") { beginEditing(item) }
            Button("Open in Pane") {
                ReaderWindowController.controller(for: session)?.openInPane(item)
            }
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
                .help("Delete all selected highlights and notes")
            Menu("Recolor") {
                ForEach(1...6, id: \.self) { color in
                    Button(HighlightCallout.name(for: color).capitalized) {
                        session.recolorAnnotations(ids: session.annotationSelection, color: color)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Change highlight color for selected items")
            Button("Export") {
                let items = session.visibleAnnotations.filter { session.annotationSelection.contains($0.id) }
                session.exportAnnotations(items)
            }
            .help("Export selected highlights and notes as Markdown")
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
                        .help("Open \(notesCaption) in Obsidian")
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
                .help(session.vaultEnabled ? "Open this chapter's notes in Obsidian" : "Start saving highlights and notes into this Obsidian vault")
                Button("Settings") { vaultSettings = true }
                    .buttonStyle(.borderless)
                    .help("Configure vault notes folder and vocabulary file")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .popover(isPresented: $vaultSettings) {
                VaultMappingForm(session: session)
            }
        }
    }
}

/// The note text lives here, not in the list row, so a later save cannot rebuild the field and drop the caret.
private struct NoteDraftEditor: View {
    var initial: String
    var commit: (String) -> Void
    var finish: () -> Void
    @State private var draft = ""
    @State private var loaded = false
    @State private var closed = false
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .font(.body)
            .frame(minHeight: 64)
            .focused($focused)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                draft = initial
                DispatchQueue.main.async { focused = true }
            }
            .onChange(of: draft) { _, text in
                guard loaded, text != initial else { return }
                commit(text)
            }
            .onChange(of: focused) { wasFocused, isFocused in
                if wasFocused && !isFocused { close() }
            }
            .onExitCommand { close() }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        commit(draft)
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
