//
//  TTYStatusView.swift
//  The small icons beside a TTY's name that show its bell, output and mute status.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// A status that a TTY's icons can show. Each case defines its symbol, its size
/// and its VoiceOver label, so adding an icon means adding a case.
enum TTYStatus: Hashable {

    /// Output has arrived since the TTY was last selected.
    case unseenOutput

    /// The TTY has rung the bell since it was last selected.
    case bell

    /// The TTY has rung the bell, and other output has also arrived, since it
    /// was last selected.
    case bellAndOutput

    /// The TTY's bell is muted.
    case muted

    /// Shown on the switcher button: a TTY other than the selected one has rung
    /// the bell and hasn't been selected since.
    case attention

    var symbol: String {
        switch self {
        case .unseenOutput, .attention: "circle.fill"
        case .bell: "bell.fill"
        case .bellAndOutput: "bell.badge.fill"
        case .muted: "bell.badge.slash"
        }
    }

    /// The symbol to use on systems that lack `symbol`.
    var fallbackSymbol: String {
        switch self {
        case .muted: "bell.slash"
        default: symbol
        }
    }

    /// The icon's point size, as a fraction of the point size of the text
    /// beside it. The dot is only a marker, unlike the bell icons, so it is
    /// drawn smaller.
    var scale: CGFloat {
        switch self {
        case .unseenOutput, .attention: 0.5
        default: 0.85
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .unseenOutput: "New output"
        case .bell: "Rang the bell"
        case .bellAndOutput: "Rang the bell, and new output"
        case .muted: "Muted"
        case .attention: "A TTY rang the bell"
        }
    }
}

/// A row of status icons, all in the accent color.
final class TTYStatusView: UIStackView {

    /// The point size of the text beside the icons, which sets their size.
    var pointSize: CGFloat = 13 {
        didSet { redraw() }
    }

    private(set) var statuses: [TTYStatus] = []

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 3
        isAccessibilityElement = true

        // Observe by selector rather than with a block: NotificationCenter removes a selector
        // observer when the observer is freed, but keeps a block observer until it is removed
        // explicitly. Search results make a new status view each time they're drawn, so block
        // observers would accumulate.
        NotificationCenter.default.addObserver(
            self, selector: #selector(accentChanged), name: Accent.didChange, object: nil)
    }

    @objc private func accentChanged() {
        redraw()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used; this view is built in code")
    }

    func show(_ statuses: [TTYStatus]) {
        guard statuses != self.statuses else { return }
        self.statuses = statuses
        redraw()
    }

    private func redraw() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }

        for status in statuses {
            // Color the symbol with a palette rather than a tint, because with a tint the badge in
            // a symbol such as bell.badge is drawn in red, whatever the tint.
            let configuration = UIImage.SymbolConfiguration(
                pointSize: pointSize * status.scale, weight: .semibold
            ).applying(UIImage.SymbolConfiguration(paletteColors: [Accent.color, Accent.color]))

            let image =
                UIImage(systemName: status.symbol, withConfiguration: configuration)
                ?? UIImage(systemName: status.fallbackSymbol, withConfiguration: configuration)
            let icon = UIImageView(image: image)
            icon.contentMode = .center
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            addArrangedSubview(icon)
        }

        isHidden = statuses.isEmpty
        accessibilityLabel = statuses.map(\.accessibilityLabel).joined(separator: ", ")
    }
}
