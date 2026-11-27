import AppKit

/// Draws the active-pane outline starting at the title strip, so it does not climb into the toolbar.
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

/// A 24-point strip at the top of a pane: book title, page, and, on the active pane, Find.
final class PaneTitleStrip: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let pageLabel = NSTextField(labelWithString: "")
    let findField = NSSearchField()
    let countLabel = NSTextField(labelWithString: "")
    private let findWidth: NSLayoutConstraint
    private var countText = ""
    private var active = true

    override init(frame frameRect: NSRect) {
        findWidth = findField.widthAnchor.constraint(equalToConstant: 160)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageLabel.font = .systemFont(ofSize: 12)
        pageLabel.setContentHuggingPriority(.required, for: .horizontal)
        pageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        findField.controlSize = .small
        findField.font = .systemFont(ofSize: 11)
        findField.focusRingType = .none
        findField.setContentHuggingPriority(.required, for: .horizontal)
        findField.setContentCompressionResistancePriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
        for item in [titleLabel, pageLabel, countLabel, findField] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pageLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            pageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pageLabel.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: findField.leadingAnchor, constant: -6),
            findField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            findField.centerYAnchor.constraint(equalTo: centerYAnchor),
            findField.heightAnchor.constraint(equalToConstant: 18),
            findWidth,
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    func show(title: String, page: String) {
        titleLabel.stringValue = title
        pageLabel.stringValue = page
        findField.placeholderString = "Find in \(title)"
    }

    func setActive(_ active: Bool) {
        self.active = active
        let color: NSColor = active ? .labelColor : .secondaryLabelColor
        titleLabel.textColor = color
        pageLabel.textColor = color
        findField.isHidden = !active
        findWidth.constant = active ? 160 : 0
        countLabel.stringValue = active ? countText : ""
        countLabel.isHidden = !active || countText.isEmpty
    }

    func setCount(_ text: String) {
        countText = text
        countLabel.stringValue = active ? text : ""
        countLabel.isHidden = !active || text.isEmpty
    }
}
