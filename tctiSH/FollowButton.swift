//
//  FollowButton.swift
//  The button that goes back to the newest output.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// A down arrow in a round capsule, floating over the top left of the terminal
/// while it has been scrolled up from the newest output. Tapping it goes back
/// to the bottom, and new output is followed again.
final class FollowButton: UIView {

    static let size: CGFloat = 44

    /// Called when the button is tapped.
    var onTap: (() -> Void)?

    private let button = UIButton(configuration: .plain())
    private let capsule = KeyBar.makeCapsule()

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Dark, like the floating switcher button, since it sits over the terminal, which is dark.
        overrideUserInterfaceStyle = .dark
        tintColor = Accent.custom

        button.configuration?.image = UIImage(systemName: "arrow.down")
        button.configuration?.baseForegroundColor = .label
        button.accessibilityLabel = "Go to Bottom"
        button.accessibilityHint = "Shows the newest output, and follows what comes after it."
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)

        addSubview(capsule)
        capsule.contentView.addSubview(button)
        KeyBar.hover(button)

        NotificationCenter.default.addObserver(
            forName: Accent.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tintColor = Accent.custom
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this view is built in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds
        button.frame = capsule.bounds
        if #unavailable(iOS 26.0) {
            capsule.layer.cornerRadius = bounds.height / 2
        }
    }
}
