import ReaderCore
import SwiftUI

/// This book's vault mapping: whether Reader writes into the vault, the notes folder, and the vocabulary file.
/// Shown as a sheet from Tools → Vault Settings… and the toolbar's vault menu.
struct VaultBookSettingsForm: View {
    @ObservedObject var session: ReaderSession
    var done: () -> Void
    @State private var notesDraft = ""
    @State private var vocabDraft = ""
    @FocusState private var field: Field?
    private enum Field { case notes, vocab }

    private var folderCaption: String {
        guard let root = session.vaultRoot, let folder = session.bookFolder else { return session.bookFolder ?? "" }
        return ObsidianLink.displayPath(vaultRoot: root, absolute: folder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vault Settings")
                    .font(.headline)
                Text(folderCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Toggle("Write notes into this vault", isOn: $session.vaultEnabled)
                .onChange(of: session.vaultEnabled) { _, _ in session.onSaveVaultState?() }
            LabeledContent("Notes folder") {
                TextField("notes", text: $notesDraft)
                    .focused($field, equals: .notes)
                    .onSubmit { commitNotes() }
            }
            LabeledContent("Vocabulary file") {
                TextField("Automatic", text: $vocabDraft)
                    .focused($field, equals: .vocab)
                    .onSubmit { commitVocabulary() }
            }
            Text("Paths are relative to the book folder. An empty vocabulary file uses learner/vocabulary.md when it exists, otherwise words.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") {
                    commitNotes()
                    commitVocabulary()
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            notesDraft = session.vaultNotesFolder
            vocabDraft = session.vaultVocabularyFile
        }
        .onChange(of: field) { _, _ in
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
