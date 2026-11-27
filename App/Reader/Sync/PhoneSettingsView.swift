import SwiftUI
import ReaderSync

struct PhoneSettingsView: View {
    @ObservedObject var controller = SyncController.shared
    @State private var secondsLeft: Int = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                connectionRow
                pairBlock
                deviceList
                if !controller.lastMessage.isEmpty {
                    Text(controller.lastMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { await controller.refreshDevices() }
            updateCountdown()
        }
        .onReceive(timer) { _ in updateCountdown() }
    }

    private var isOffline: Bool { controller.status.state == .error }

    private var connectionRow: some View {
        HStack {
            Circle()
                .fill(Color(hex: isOffline ? "EB5757" : "27AE60"))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(isOffline ? "Can't reach Mac mini" : "Connected over Tailscale")
                    .font(.headline)
                Text(controller.status.hostCaption)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isOffline {
                Button("Retry") { Task { await controller.retry() } }
            } else {
                Text(controller.status.label)
                    .foregroundStyle(Color(hex: "27AE60"))
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var pairBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair a phone").font(.headline)
                    Text("Open Reader on your phone and scan this code. Only works on your Tailscale network.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.issuedQR == nil && !isOffline {
                    Button("Show QR code") { Task { await controller.showPhoneQR() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            if isOffline {
                Text("Pairing needs the Mac mini online. Check Tailscale, then retry.")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            if let qr = controller.issuedQR, !isOffline {
                HStack(alignment: .center, spacing: 20) {
                    ZStack {
                        Color.white
                        if let image = controller.qrImage {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 160, height: 160)
                        }
                    }
                    .frame(width: 180, height: 180)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Open Reader on your phone.\n2. Tap Scan QR code and point at this square.\n3. Your books and highlights start syncing right away.")
                            .font(.subheadline)
                        Text(secondsLeft > 0 ? "One-time code · expires in \(minutesSeconds(secondsLeft))" : "Code expired")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        HStack {
                            Button("Refresh code") { Task { await controller.showPhoneQR() } }
                            Button("Done") { controller.dismissQR() }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var visibleDevices: [PairedDevice] {
        controller.devices
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired devices (\(visibleDevices.count))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(visibleDevices) { device in
                    deviceRow(device)
                    if device.deviceId != visibleDevices.last?.deviceId {
                        Divider()
                    }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            Text("Revoking removes the phone's token immediately. Highlights already synced stay in your vault.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceId == controller.macDeviceId ? "\(device.name) (This Mac)" : device.name)
                    .font(.body.weight(.medium))
                Text(deviceCaption(device))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if device.deviceId != controller.macDeviceId {
                if controller.confirmRevokeId == device.deviceId {
                    Text("Stop syncing this phone?")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Revoke access") { Task { await controller.revoke(device.deviceId) } }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel") { controller.confirmRevokeId = nil }
                } else {
                    Button("Revoke") { controller.confirmRevokeId = device.deviceId }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func deviceCaption(_ device: PairedDevice) -> String {
        let platform: String
        switch device.platform {
        case "macos": platform = "Mac"
        case "android": platform = "Android"
        case "ios": platform = "iOS"
        default: platform = device.platform.capitalized
        }
        if let seen = device.lastSeenAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "\(platform) · Synced \(formatter.localizedString(for: seen, relativeTo: Date()))"
        }
        return platform
    }

    private func updateCountdown() {
        guard let expiry = controller.issuedQR?.expiresAt else {
            secondsLeft = 0
            return
        }
        secondsLeft = max(0, Int(expiry.timeIntervalSinceNow))
    }

    private func minutesSeconds(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
