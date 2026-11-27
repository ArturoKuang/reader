import SwiftUI
import ReaderSync

struct ConflictReviewView: View {
    @ObservedObject var controller = SyncController.shared
    @State private var index = 0
    @State private var editingMerge = false
    @State private var mergeDraft = ""
    @Environment(\.dismiss) private var dismiss

    private var conflicts: [OpenConflict] { controller.conflicts() }

    var body: some View {
        Group {
            if conflicts.isEmpty {
                emptyState
            } else {
                review
            }
        }
        .frame(minWidth: 640, idealWidth: 640, maxWidth: 640, minHeight: 320, idealHeight: 520, maxHeight: 540)
        .background(.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("All conflicts resolved")
                .font(.headline)
                .foregroundStyle(Color(hex: "27AE60"))
            Text("Your highlights and vault notes are back in sync.")
                .font(.title3.weight(.semibold))
            Text("The toolbar chip returns to green Synced and this sheet closes automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var review: some View {
        let current = conflicts[min(index, conflicts.count - 1)]
        let macIds = Set(controller.devices.filter(\.isMac).map(\.deviceId) + [controller.macDeviceId])
        return VStack(spacing: 0) {
            header(count: conflicts.count)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    context(current)
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(current.sides.enumerated()), id: \.offset) { offset, side in
                            sideCard(conflict: current, side: side, index: offset, isMac: macIds.contains(side.deviceId))
                        }
                    }
                    if !editingMerge {
                        HStack {
                            Text("Picking one updates TailDrive and your MacBook's vault note. No conflict files are written to the vault.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button("Combine both notes…") {
                                mergeDraft = ConflictResolution.defaultCombinedBody(conflict: current, macDeviceIds: macIds)
                                editingMerge = true
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Combined note (saves with Mac highlight color)")
                                .font(.subheadline.weight(.semibold))
                            TextEditor(text: $mergeDraft)
                                .font(.body)
                                .frame(minHeight: 72)
                                .padding(6)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                            HStack {
                                Button("Save combined note") {
                                    Task {
                                        await controller.resolve(conflict: current, choice: .combineNotes(body: mergeDraft))
                                        editingMerge = false
                                        index = min(index, max(controller.conflicts().count - 1, 0))
                                    }
                                }
                                .keyboardShortcut(.defaultAction)
                                Button("Cancel") { editingMerge = false }
                            }
                        }
                        .padding(14)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
                    }
                }
                .padding(20)
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack {
            Circle().fill(Color(hex: "F2994A")).frame(width: 9, height: 9)
            Text(count == 1 ? "1 version to review" : "\(count) versions to review")
                .font(.headline)
            Spacer()
            Text("Item \(min(index + 1, count)) of \(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Previous") {
                editingMerge = false
                index = max(0, index - 1)
            }
            .disabled(index == 0)
            Button("Next") {
                editingMerge = false
                index = min(count - 1, index + 1)
            }
            .disabled(index >= count - 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.5))
    }

    private func context(_ conflict: OpenConflict) -> some View {
        let quote = conflict.sides.first?.payload?["quote"] as? String ?? ""
        let color = conflict.sides.first?.payload?["color"] as? Int ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(conflict.bookId).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(conflict.kind.rawValue).font(.caption).foregroundStyle(.tertiary)
            }
            Text("“\(quote)”")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(hex: RecordAdapter.highlightColorHex(color))).frame(width: 3)
                }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sideCard(conflict: OpenConflict, side: ConflictSide, index: Int, isMac: Bool) -> some View {
        let display = ConflictResolution.display(side: side, devices: controller.devices)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(display.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(display.time).font(.caption).foregroundStyle(.tertiary)
            }
            if display.deleted {
                Text("Deleted on \(display.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: RecordAdapter.highlightColorHex(display.color))).frame(width: 12, height: 12)
                    Text("\(display.colorName) highlight").font(.caption).foregroundStyle(.secondary)
                }
                Text(display.note)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Button(isMac ? "Keep Mac version" : "Keep phone version") {
                Task {
                    await controller.resolve(conflict: conflict, choice: .keepSide(index))
                    self.index = min(self.index, max(controller.conflicts().count - 1, 0))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isMac ? Color.accentColor : Color.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .top)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }
}
