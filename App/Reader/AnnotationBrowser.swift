import ReaderCore
import SwiftUI

/// The notes list shared by the inspector and the Highlights and Notes sidebar.
struct AnnotationBrowser: View {
    @ObservedObject var session: ReaderSession
    var onJump: (Annotation) -> Void
    @State private var editing: String?
    @State private var vaultSettings = false
    @State private var suppressJump = false

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
            if session.visibleAnnotations.isEmpty {
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
                    ForEach(AnnotationIndex.grouped(session.visibleAnnotations)) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                row(item)
                                    .tag(item.id)
                                    .contextMenu { context(item) }
                            }
                        }
                    }
                }
                .onChange(of: session.annotationSelection) { _, ids in
                    guard !suppressJump, ids.count == 1, let id = ids.first, let item = session.visibleAnnotations.first(where: { $0.id == id }) else { return }
                    onJump(item)
                }
                .onCopyCommand {
                    let chosen = session.visibleAnnotations.filter { session.annotationSelection.contains($0.id) }
                    return [NSItemProvider(object: session.annotationMarkdown(chosen) as NSString)]
                }
                .onExitCommand {
                    if editing != nil {
                        editing = nil
                        session.flushNoteBodies()
                    } else {
                        session.annotationSelection = []
                    }
                }
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
                if editing == item.id {
                    TextEditor(text: binding(item))
                        .font(.body)
                        .frame(minHeight: 64)
                        .onExitCommand { editing = nil; session.flushNoteBodies() }
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
                    let concepts = ConceptsFile.suggested(passage: item.quote, concepts: session.concepts, chapter: ChapterFiles.number(in: item.section ?? ""))
                    if !concepts.isEmpty {
                        Text(concepts.map(\.id).joined(separator: " ")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = item.note?.id ?? item.id }
        .simultaneousGesture(TapGesture().onEnded { onJump(item) })
    }

    private func binding(_ item: Annotation) -> Binding<String> {
        let id = item.note?.id ?? item.id
        return Binding(
            get: { session.notes.first { $0.id == id }?.body ?? item.body },
            set: { session.queueNoteBody(id: id, body: $0) }
        )
    }

    @ViewBuilder private func context(_ item: Annotation) -> some View {
        Button("Edit Note") { editing = item.note?.id ?? item.id }
        Menu("Color") {
            ForEach(1...6, id: \.self) { color in
                Button("Color \(color)") { session.recolorAnnotation(id: item.highlight?.id ?? item.id, color: color) }
            }
        }
        Button("Copy Quote") { paste(item.quote) }
        Button("Copy as Markdown") { paste(session.annotationMarkdown([item])) }
        Button("Copy Link") {
            let link = ReaderLink(path: session.bookURL.path, location: item.cfi ?? item.page.map { "page=\($0)" }, id: item.id)
            paste(link.url)
        }
        if session.usesVault {
            Button("Reveal in Obsidian") { session.onRevealInObsidian?() }
        }
        if session.annotationSelection.count > 1, session.annotationSelection.contains(item.id) {
            Button("Delete \(session.annotationSelection.count) Items") { session.deleteSelectedAnnotations() }
        } else {
            Button("Remove Highlight & Note") { session.deleteAnnotations(ids: [item.id]) }
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

    @ViewBuilder private var vaultFooter: some View {
        if session.usesVault {
            HStack {
                Text(session.vaultEnabled ? "Obsidian · notes/\(ChapterFiles.notesFile(chapter: ChapterFiles.number(in: session.sectionTitle), bookTitle: session.bookURL.deletingPathExtension().lastPathComponent))" : "Not saving to vault")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(session.vaultEnabled ? "Reveal" : "Enable") {
                    if session.vaultEnabled {
                        session.onRevealInObsidian?()
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
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Write notes into this vault", isOn: $session.vaultEnabled)
                        .onChange(of: session.vaultEnabled) { _, _ in session.onSaveVaultState?() }
                    TextField("Notes folder", text: $session.vaultNotesFolder)
                        .onChange(of: session.vaultNotesFolder) { _, _ in session.onSaveVaultState?() }
                    TextField("Vocabulary file", text: $session.vaultVocabularyFile)
                        .onChange(of: session.vaultVocabularyFile) { _, _ in session.onSaveVaultState?() }
                }
                .padding(12)
                .frame(width: 280)
            }
        }
    }
}
