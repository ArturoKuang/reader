import SwiftUI
import ReaderSync

struct SyncStatusChipView: View {
    @ObservedObject var controller = SyncController.shared

    var body: some View {
        Button(action: {
            if controller.status.state == .conflict {
                controller.handleChipClick()
            } else if controller.status.state == .error {
                Task { await controller.retry() }
            } else if controller.status.state == .storageFull {
                Task { await controller.checkAgain() }
            }
        }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: controller.status.state.dotHex))
                    .frame(width: 8, height: 8)
                    .opacity(controller.status.state.animates ? 0.55 : 1)
                Text(chipLabel)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(controller.status.detail ?? controller.status.label)
        .sheet(isPresented: $controller.showingConflictReview) {
            ConflictReviewView()
        }
        .popover(isPresented: Binding(
            get: { popoverVisible },
            set: { if !$0 { popoverVisible = false } }
        )) {
            statusPopover
                .padding(14)
                .frame(width: 280)
        }
    }

    @State private var popoverVisible = false

    private var chipLabel: String { controller.status.label }

    private var statusPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: controller.status.state.dotHex)).frame(width: 9, height: 9)
                Text(controller.status.label).font(.headline)
            }
            if let detail = controller.status.detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(controller.status.hostCaption)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if controller.status.state == .storageFull {
                ForEach(controller.engine?.waitingBooks() ?? [], id: \.sha256) { book in
                    Text("\(book.title) — Waiting for space")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Check again") { Task { await controller.checkAgain() } }
            }
            if controller.status.state == .error {
                Button("Retry") { Task { await controller.retry() } }
            }
            if controller.status.state == .conflict {
                Button("Review versions") { controller.showingConflictReview = true }
            }
        }
    }
}
