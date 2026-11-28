import SwiftUI
import ReaderSync

struct SyncStatusChipView: View {
    @ObservedObject var controller = SyncController.shared
    @State private var popoverVisible = false

    var body: some View {
        Button(action: handleClick) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(hex: controller.status.state.dotHex))
                    .frame(width: 7, height: 7)
                    .opacity(controller.status.state.animates ? 0.55 : 1)
                Text(chipLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltipText)
        .sheet(isPresented: $controller.showingConflictReview) {
            ConflictReviewView()
        }
        .popover(isPresented: $popoverVisible) {
            statusPopover
                .padding(14)
                .frame(width: 280)
        }
    }

    private var chipLabel: String { controller.status.label }

    private var tooltipText: String {
        if let detail = controller.status.detail, !detail.isEmpty {
            return "Sync: \(controller.status.label) — \(detail)"
        }
        return "Sync: \(controller.status.label) — Click for sync status and manual sync"
    }

    private func handleClick() {
        switch controller.status.state {
        case .conflict:
            controller.handleChipClick()
        case .error:
            popoverVisible = true
            Task { await controller.retry() }
        case .storageFull:
            popoverVisible = true
            Task { await controller.checkAgain() }
        case .synced, .syncing, .offline:
            popoverVisible.toggle()
        }
    }

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
                    .help("Check whether TailDrive storage has space available")
            } else if controller.status.state == .error {
                Button("Retry") { Task { await controller.retry() } }
                    .help("Retry syncing with TailDrive")
            } else if controller.status.state == .conflict {
                Button("Review versions") {
                    popoverVisible = false
                    controller.showingConflictReview = true
                }
                .help("Open conflict review to pick which version to keep")
            } else {
                Button("Sync Now") { Task { await controller.syncNow() } }
                    .help("Push local changes and pull updates now")
            }
        }
    }
}
