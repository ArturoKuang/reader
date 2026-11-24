import AppKit

/// Side-by-side document panes inside the existing center split item.
/// A narrow window stacks the same panes vertically. Nothing here is saved.
final class PaneHostController: NSViewController {
    let split = NSSplitView()
    private(set) var panes: [NSViewController] = []
    private(set) var activeIndex = 0
    private var needsEqualShare = false

    override func loadView() {
        split.isVertical = true
        split.dividerStyle = .thin
        view = split
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        equalizeIfNeeded()
    }

    func adopt(_ controller: NSViewController) {
        add(controller)
        showBorder()
    }

    func replace(at index: Int, with controller: NSViewController) {
        guard panes.indices.contains(index) else { return }
        let old = panes[index]
        old.view.removeFromSuperview()
        old.removeFromParent()
        addChild(controller)
        controller.view.wantsLayer = true
        split.insertArrangedSubview(controller.view, at: index)
        panes[index] = controller
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
        for index in split.subviews.indices {
            split.setHoldingPriority(.defaultLow, forSubviewAt: index)
        }
        if !panes.isEmpty { needsEqualShare = true }
        split.addArrangedSubview(controller.view)
        if let index = split.subviews.firstIndex(where: { $0 === controller.view }) {
            split.setHoldingPriority(.defaultLow, forSubviewAt: index)
        }
        panes.append(controller)
        DispatchQueue.main.async { [weak self] in
            self?.equalizeIfNeeded()
        }
    }

    private func equalizeIfNeeded() {
        guard needsEqualShare, panes.count > 1 else { return }
        let vertical = split.isVertical
        let total = vertical ? split.bounds.width : split.bounds.height
        guard total > 40 else { return }
        needsEqualShare = false
        let divider = split.dividerThickness
        let share = (total - divider * CGFloat(panes.count - 1)) / CGFloat(panes.count)
        var position = share
        for index in 0..<(panes.count - 1) {
            split.setPosition(position, ofDividerAt: index)
            position += share + divider
        }
    }

    private func showBorder() {
        let accent = panes.count > 1
        for (index, pane) in panes.enumerated() {
            pane.view.layer?.borderWidth = accent && index == activeIndex ? 2 : 0
            pane.view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
}
