import AppKit
import ReaderCore
import SwiftUI

struct UpdateWindowView: View {
    @ObservedObject var updater: AppUpdater
    var onInstall: (UpdateRelease) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.headline)
                    Text("Installed: \(updater.currentBuild.version)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            content

            HStack {
                if let release = skippableRelease {
                    Button("Skip This Build") {
                        updater.skipRelease(release)
                        onClose()
                    }
                }
                Spacer()
                actionButtons
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var skippableRelease: UpdateRelease? {
        switch updater.state {
        case .available(let release), .readyToInstall(let release, _):
            return release
        default:
            return nil
        }
    }

    private var headline: String {
        switch updater.state {
        case .idle, .checking:
            return "Checking for Updates…"
        case .upToDate:
            return "Reader is Up to Date"
        case .available(let release):
            return "Update Available — \(release.version)"
        case .downloading(let release, _):
            return "Downloading \(release.shortSHA)…"
        case .readyToInstall(let release, _):
            return "Update Ready — \(release.version)"
        case .installing(let release):
            return "Installing \(release.shortSHA)…"
        case .error:
            return "Update Check Failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking GitHub Releases on main…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

        case .upToDate:
            Text("You are running the latest build on main (\(updater.currentBuild.shortSHA)).")
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)

        case .available(let release):
            releaseDetails(release, readyNote: nil)

        case .readyToInstall(let release, _):
            releaseDetails(
                release,
                readyNote: updater.autoInstallOnQuit
                    ? "Downloaded and verified. It will install automatically when you quit Reader, or restart now."
                    : "Downloaded and verified. Restart Reader to apply it immediately."
            )

        case .downloading(_, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))% downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Downloading release archive…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)

        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Verifying archive and restarting Reader…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

        case .error(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func releaseDetails(_ release: UpdateRelease, readyNote: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let readyNote {
                Text(readyNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !release.notes.isEmpty {
                Text("Changes")
                    .font(.subheadline.weight(.medium))
                ScrollView {
                    Text(release.notes)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 80, maxHeight: 160)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
            if let url = URL(string: release.releaseURL) {
                Link("View release on GitHub", destination: url)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch updater.state {
        case .idle, .checking, .installing:
            Button("Close", action: onClose)
                .disabled(updater.state.isBusy)
        case .upToDate:
            Button("Check Again") {
                updater.checkForUpdates(manual: true)
            }
            Button("OK", action: onClose)
                .keyboardShortcut(.defaultAction)
        case .available(let release):
            Button("Later", action: onClose)
            Button("Update & Restart") {
                onInstall(release)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .readyToInstall(let release, _):
            Button(updater.autoInstallOnQuit ? "Install on Quit" : "Later", action: onClose)
            Button("Restart to Update") {
                onInstall(release)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Close", action: onClose)
                .disabled(true)
        case .error:
            Button("Close", action: onClose)
            Button("Try Again") {
                updater.checkForUpdates(manual: true)
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
