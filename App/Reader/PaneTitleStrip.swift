import AppKit

/// Draws the active-pane outline below the toolbar, so it does not climb into the toolbar.
final class PaneFocusRing: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("pane-focus-ring")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

/// Collapsible Find bar at the top of a pane. Completely hidden (0 height) until invoked via ⌘F,
/// so no redundant title/page strip sits above the reading surface.
final class PaneTitleStrip: NSView {
    let findField = NSSearchField()
    let countLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton()
    let nextButton = NSButton()
    let closeButton = NSButton()
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?
    private var heightConstraint: NSLayoutConstraint?
    private var countText = ""
    private var active = true
    private(set) var isFindVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        findField.controlSize = .small
        findField.font = .systemFont(ofSize: 12)
        findField.focusRingType = .none
        findField.sendsSearchStringImmediately = true
        findField.sendsWholeSearchString = false
        findField.placeholderString = "Find in book"
        findField.toolTip = "Search text in this book"
        findField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        findField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureButton(previousButton, symbol: "chevron.up", label: "Previous Match", tip: "Previous Match (⇧⌘G)", action: #selector(previousClicked))
        configureButton(nextButton, symbol: "chevron.down", label: "Next Match", tip: "Next Match (⌘G)", action: #selector(nextClicked))
        configureButton(closeButton, symbol: "xmark", label: "Close Find Bar", tip: "Close Find Bar (Esc)", action: #selector(closeClicked))

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        for item in [findField, countLabel, previousButton, nextButton, closeButton, line] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }

        let height = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            findField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            findField.centerYAnchor.constraint(equalTo: centerYAnchor),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            findField.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            countLabel.leadingAnchor.constraint(equalTo: findField.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 6),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 22),
            previousButton.heightAnchor.constraint(equalToConstant: 20),
            nextButton.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 22),
            nextButton.heightAnchor.constraint(equalToConstant: 20),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: nextButton.trailingAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    func show(title: String, page: String) {
        findField.placeholderString = "Find in \(title)"
    }

    func setFindVisible(_ visible: Bool) {
        isFindVisible = visible
        isHidden = !visible
        heightConstraint?.constant = visible ? 32 : 0
        countLabel.stringValue = (visible && active) ? countText : ""
        countLabel.isHidden = !visible || !active || countText.isEmpty
        superview?.needsLayout = true
    }

    func setActive(_ active: Bool) {
        self.active = active
        countLabel.stringValue = (isFindVisible && active) ? countText : ""
        countLabel.isHidden = !isFindVisible || !active || countText.isEmpty
    }

    func setCount(_ text: String) {
        countText = text
        countLabel.stringValue = (isFindVisible && active) ? text : ""
        countLabel.isHidden = !isFindVisible || !active || text.isEmpty
    }

    private func configureButton(_ button: NSButton, symbol: String, label: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    @objc private func previousClicked() { onPrevious?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func closeClicked() { onClose?() }
}
