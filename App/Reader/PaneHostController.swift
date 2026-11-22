import AppKit

/// Side-by-side document panes inside the existing center split item.
/// A narrow window stacks the same panes vertically. Nothing here is saved.
final class PaneHostController: NSViewController {
    let split = NSSplitView()
    private(set) var panes: [NSViewController] = []
    private(set) var activeIndex = 0

    override func loadView() {
        split.isVertical = true
        split.dividerStyle = .thin
        view = split
    }

    func adopt(_ controller: NSViewController) {
        add(controller)
        showBorder()
    }

    func addPane(_ controller: NSViewController, sideBySide: Bool) {
        split.isVertical = sideBySide
        add(controller)
        showBorder()
    }

    /// Closes the active pane when another one remains.
    func closeActive() -> Bool {
        guard panes.count > 1 else { return false }
        let pane = panes.remove(at: activeIndex)
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        activeIndex = min(activeIndex, panes.count - 1)
        showBorder()
        return true
    }

    func focus(at index: Int) {
        guard panes.indices.contains(index) else { return }
        activeIndex = index
        showBorder()
    }

    func focusNext(backward: Bool) {
        guard panes.count > 1 else { return }
        let delta = backward ? -1 : 1
        activeIndex = (activeIndex + delta + panes.count) % panes.count
        showBorder()
    }

    func stackForWindowWidth(_ width: CGFloat) {
        guard panes.count > 1 else { return }
        split.isVertical = width >= 900
    }

    func index(at windowPoint: NSPoint) -> Int? {
        for (index, pane) in panes.enumerated() {
            let local = pane.view.convert(windowPoint, from: nil)
            if pane.view.bounds.contains(local) { return index }
        }
        return nil
    }

    private func add(_ controller: NSViewController) {
        addChild(controller)
        controller.view.wantsLayer = true
        split.addArrangedSubview(controller.view)
        panes.append(controller)
    }

    private func showBorder() {
        let accent = panes.count > 1
        for (index, pane) in panes.enumerated() {
            pane.view.layer?.borderWidth = accent && index == activeIndex ? 2 : 0
            pane.view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
}
