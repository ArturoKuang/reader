import AppKit
import ReaderCore

/// The small bar that appears above a finished text selection.
final class SelectionBarController: NSObject {
    private let popover = NSPopover()
    private weak var session: ReaderSession?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
    }

    func dismiss() {
        popover.performClose(nil)
    }

    func show(session: ReaderSession, relativeTo rect: NSRect, of view: NSView) {
        guard session.settings.showSelectionBar else { return }
        self.session = session
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        for color in 1...6 {
            let button = NSButton()
            button.setButtonType(.momentaryPushIn)
            button.isBordered = false
            button.tag = color
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Color \(color)")
            if let parts = HighlightAppearance.components(color: color, dark: false) {
                button.contentTintColor = NSColor(calibratedRed: parts.r, green: parts.g, blue: parts.b, alpha: 1)
            }
            button.target = self
            button.action = #selector(color(_:))
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(labeled("Note", #selector(note)))
        row.addArrangedSubview(labeled("Look Up", #selector(lookUp)))
        row.addArrangedSubview(labeled("Ask AI", #selector(ask)))
        row.addArrangedSubview(labeled("Copy", #selector(copyText)))
        let host = NSViewController()
        host.view = row
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    @objc private func color(_ sender: NSButton) {
        session?.highlight(color: sender.tag)
        dismiss()
    }
    @objc private func note() { session?.addNote(); dismiss() }
    @objc private func lookUp() { session?.lookUp(); dismiss() }
    @objc private func ask() { session?.show(tab: .askAI); dismiss() }
    @objc private func copyText() {
        guard let text = session?.selection?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        dismiss()
    }

    private func labeled(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 12)
        return button
    }
}
