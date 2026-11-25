import AppKit
import ReaderCore

/// The right-click menu of a highlight, the same in PDF, EPUB, and Markdown.
/// The owner keeps the builder alive for as long as its menus can be open.
final class HighlightContextMenuBuilder: NSObject {
    weak var session: ReaderSession?

    func menu(for id: String) -> NSMenu {
        let menu = NSMenu()
        let item = session?.annotation(matching: id)
        let currentColor = item?.color

        let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for index in 1...6 {
            let entry = NSMenuItem(title: HighlightCallout.name(for: index).capitalized, action: #selector(recolor(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = id
            entry.tag = index
            entry.state = index == currentColor ? .on : .off
            entry.image = Self.dot(index)
            colors.addItem(entry)
        }
        color.submenu = colors
        // A standalone note has no highlight to color.
        color.isEnabled = item?.highlight != nil
        menu.addItem(color)
        menu.addItem(entry("Add/Edit Note", #selector(editNote(_:)), id))
        menu.addItem(.separator())
        menu.addItem(entry("Copy", #selector(copyQuote(_:)), id))
        menu.addItem(entry("Copy Link", #selector(copyLink(_:)), id))
        menu.addItem(.separator())
        if item?.hasNote == true {
            menu.addItem(entry("Remove Note", #selector(removeNote(_:)), id))
        }
        let removeTitle = item?.hasNote == true ? "Remove Highlight & Note" : "Remove Highlight"
        menu.addItem(entry(removeTitle, #selector(removeHighlight(_:)), id))
        return menu
    }

    private func entry(_ title: String, _ action: Selector, _ id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    private static func dot(_ color: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            ReaderColor.nsColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }

    @objc private func recolor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        session?.recolorAnnotation(id: id, color: sender.tag)
    }

    @objc private func editNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        session?.lastAnnotationHit = id
        session?.openAnnotation(id)
    }

    @objc private func copyQuote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let quote = session?.annotation(matching: id)?.quote else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quote, forType: .string)
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let session, let id = sender.representedObject as? String, let item = session.annotation(matching: id) else { return }
        let link = CopyLink.make(path: session.bookURL.path, page: item.page, cfi: item.cfi, quote: item.quote)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
    }

    @objc private func removeNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        session?.removeNoteOnly(id: id)
    }

    @objc private func removeHighlight(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        session?.deleteHighlight(id: id)
    }
}
