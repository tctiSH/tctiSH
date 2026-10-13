//
//  SwitcherButton.swift
//  The button that opens the TTY switcher, and swipes through open TTYs.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// A button that opens the TTY switcher when tapped. Pulling it left or right
/// steps to the next or previous TTY in the step order, without opening the
/// switcher. Pulling it left from the last TTY shows a plus, and letting go
/// then adds a TTY.
///
/// The symbol follows the finger a short way, resisting more the further the
/// finger goes, and springs back on release. The capsule around the button
/// stretches to keep the symbol inside it.
///
/// Holding the button shows the selected TTY's menu, the same menu its card
/// shows in the switcher.
///
/// The button shows a dot while a TTY other than the selected one has rung its
/// bell and not been looked at since.
final class SwitcherButton: UIButton {

    /// The button's resting symbol, the one used for a set of tabs.
    static let symbol = "square.on.square"

    /// What pulling the button in one direction would do.
    enum Pull {
        /// Step to the TTY in that direction.
        case step

        /// Add a TTY, since there is none further in that direction.
        case add

        /// Nothing: there is no TTY in that direction, and no more can be
        /// opened. A pull far enough to add one says why instead.
        case full

        /// Nothing: there is no TTY in that direction.
        case none
    }

    /// Opens the switcher.
    var open: () -> Void = {}

    /// Steps by one TTY: +1 for the next, -1 for the previous.
    var step: (Int) -> Void = { _ in }

    /// Adds a TTY after the last.
    var add: () -> Void = {}

    /// Says that no more TTYs can be added, for a pull that would have added
    /// one.
    var atLimit: () -> Void = {}

    /// What a pull towards the next TTY (+1) or the previous (-1) would do.
    var pull: (Int) -> Pull = { _ in .none }

    /// Returns the selected TTY's menu for the given interaction to show, or
    /// nil for no menu.
    var ttyMenu: (UIContextMenuInteraction) -> UIMenu? = { _ in nil }

    /// How far the finger must move for letting go to step or to add. A fast
    /// flick also steps, however short.
    private static let stepDistance: CGFloat = 24
    private static let addDistance: CGFloat = 56

    /// The farthest the symbol moves when a pull would step, add, or do
    /// nothing, however far the finger goes.
    private static let stepReach: CGFloat = 12
    private static let addReach: CGFloat = 30
    private static let stuckReach: CGFloat = 4

    /// The visible button, styled like the key bar's other buttons, with
    /// touches disabled. It slides with a pull while this button, which takes
    /// the touches, stays in place.
    private let face = UIButton(configuration: .plain())
    private let dot = TTYStatusView()

    /// What letting go now would do. The face's symbol shows it.
    private enum Armed: Equatable {
        case none
        case step(Int)
        case add
    }
    private var armed = Armed.none

    /// While stretched: the capsule's resting frame, and the resting centers of
    /// the views in its content view, which the stretch is measured from.
    private var rest: (capsule: CGRect, centers: [(view: UIView, center: CGPoint)])?

    /// How far the capsule is stretched: negative to the left, positive to the
    /// right, and 0 at rest.
    private var stretched: CGFloat = 0

    init() {
        super.init(frame: .zero)

        face.configuration?.image = UIImage(systemName: Self.symbol)
        face.configuration?.baseForegroundColor = .label
        face.isUserInteractionEnabled = false
        addSubview(face)

        accessibilityLabel = "Show TTYs"
        accessibilityHint = "Swipe left or right to switch to the next or previous TTY."

        addAction(UIAction { [weak self] _ in self?.open() }, for: .touchUpInside)

        // Holding the button still opens the TTY menu, and a tap opens the switcher. Moving the
        // finger before the menu appears makes the touch a pull instead, and the menu doesn't open.
        isContextMenuInteractionEnabled = true
        showsMenuAsPrimaryAction = false

        // A two-finger swipe on a trackpad pulls the button as a finger does.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedScrollTypesMask = .continuous
        addGestureRecognizer(pan)

        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Next TTY") { [weak self] _ in
                self?.step(1)
                return true
            },
            UIAccessibilityCustomAction(name: "Previous TTY") { [weak self] _ in
                self?.step(-1)
                return true
            },
        ]

        dot.pointSize = 15
        dot.isUserInteractionEnabled = false
        face.addSubview(dot)

        NotificationCenter.default.addObserver(
            forName: TTYs.statusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshDot()
        }
        NotificationCenter.default.addObserver(
            forName: TTYs.selectionDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshDot()
        }
        // Closing the TTY that rang its bell can clear the dot.
        NotificationCenter.default.addObserver(
            forName: TTYs.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshDot()
        }
        refreshDot()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this button is built in code")
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = ttyMenu(interaction) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menu })
    }

    override var isHighlighted: Bool {
        didSet { face.isHighlighted = isHighlighted }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Set by bounds and center rather than frame: during a pull the face has a translation
        // transform, and UIKit leaves a view's frame undefined while its transform isn't the
        // identity.
        face.bounds = bounds
        face.center = CGPoint(x: bounds.midX, y: bounds.midY)
        face.layoutIfNeeded()

        // The dot is centered on the symbol's top-right corner, where a badge goes.
        let size = dot.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let symbol = face.imageView?.frame ?? face.bounds
        dot.frame = CGRect(
            x: symbol.maxX - size.width / 2, y: symbol.minY - size.height / 2,
            width: size.width, height: size.height)
    }

    private func refreshDot() {
        dot.show(TTYs.shared.needsAttention ? [.attention] : [])
        accessibilityValue = dot.statuses.isEmpty ? nil : TTYStatus.attention.accessibilityLabel
        setNeedsLayout()
    }

    // MARK: Pulling

    /// Lets the pan begin only for a mostly horizontal movement, leaving a
    /// vertical one to other gestures.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gesture)
        }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let distance = pan.translation(in: self).x

        // Pulling left steps to the next TTY, which comes in from the right as a page does; pulling
        // right steps to the previous one.
        let offset = distance < 0 ? 1 : -1
        let pull = self.pull(offset)

        switch pan.state {
        case .began, .changed:
            let reach: CGFloat =
                switch pull {
                case .step: Self.stepReach
                case .add: Self.addReach
                case .full, .none: Self.stuckReach
                }
            let moved = Self.resisted(distance, reach: reach)
            face.transform = CGAffineTransform(translationX: moved, y: 0)
            stretch(moved)
            switch pull {
            case .step: arm(abs(distance) >= Self.stepDistance ? .step(offset) : .none)
            case .add: arm(abs(distance) >= Self.addDistance ? .add : .none)
            case .full, .none: arm(.none)
            }

        case .ended:
            let velocity = pan.velocity(in: self).x
            switch pull {
            case .step:
                let flicked = abs(velocity) > 300 && (velocity < 0) == (distance < 0)
                if abs(distance) >= Self.stepDistance || flicked {
                    step(offset)
                }
            case .add:
                if armed == .add {
                    add()
                }
            case .full:
                if abs(distance) >= Self.addDistance {
                    atLimit()
                }
            case .none:
                break
            }
            springBack()

        default:
            springBack()
        }
    }

    /// How far the symbol moves when the finger has moved `distance`: 0.6 as
    /// far at first, then less and less, approaching `reach` but never passing
    /// it.
    private static func resisted(_ distance: CGFloat, reach: CGFloat) -> CGFloat {
        let magnitude = reach * (1 - 1 / (abs(distance) / reach * 0.6 + 1))
        return distance < 0 ? -magnitude : magnitude
    }

    /// Records what letting go would do and shows it on the face: an arrow
    /// pointing the way of the pull to step, a plus to add, and the resting
    /// symbol for nothing. The dot is hidden while armed.
    private func arm(_ armed: Armed) {
        guard armed != self.armed else { return }
        self.armed = armed
        if armed != .none {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        let symbol =
            switch armed {
            case .none: Self.symbol
            case .step(let offset): offset > 0 ? "arrow.left" : "arrow.right"
            case .add: "plus"
            }
        let image = UIImage(systemName: symbol)
        if let imageView = face.imageView {
            UIView.transition(
                with: imageView, duration: 0.15, options: [.transitionCrossDissolve]
            ) {
                self.face.configuration?.image = image
            }
        } else {
            face.configuration?.image = image
        }
        dot.isHidden = armed != .none
    }

    /// Widens the capsule the button is in by `moved`, on the side the symbol
    /// has moved toward, so the symbol stays inside it. Everything in the
    /// capsule, this button included, keeps its place on screen.
    private func stretch(_ moved: CGFloat) {
        stretched = moved
        guard let capsule = capsule else { return }
        let content = capsule.contentView
        if rest == nil {
            rest = (capsule.frame, content.subviews.map { ($0, $0.center) })
        }
        guard let rest else { return }

        var frame = rest.capsule
        frame.size.width += abs(moved)
        if moved < 0 {
            frame.origin.x += moved
        }
        capsule.frame = frame

        // The content view moves with the capsule's left edge, so shift its subviews back by as
        // much to keep them still on screen.
        let shift = frame.minX - rest.capsule.minX
        for (view, center) in rest.centers {
            view.center = CGPoint(x: center.x - shift, y: center.y)
        }
    }

    /// Call after laying out the capsule this button is in. Layout resets the
    /// capsule and its contents, undoing any stretch, and may have moved their
    /// resting places; this records the new resting places and applies the
    /// current stretch again from them.
    func capsuleLaidOut() {
        rest = nil
        if stretched != 0 {
            stretch(stretched)
        }
    }

    /// The capsule the button is in: the nearest visual effect view among its
    /// superviews. It is searched for because the effect view's content view is
    /// not always a direct subview of it.
    private var capsule: UIVisualEffectView? {
        var view = superview
        while let current = view {
            if let effect = current as? UIVisualEffectView {
                return effect
            }
            view = current.superview
        }
        return nil
    }

    private func springBack() {
        arm(.none)
        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.65, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.face.transform = .identity
            self.stretch(0)
        } completion: { _ in
            if self.face.transform == .identity {
                self.rest = nil
            }
        }
    }
}

// MARK: - Floating

/// A switcher button alone in a round capsule, floating over the bottom right
/// of the terminal while the key bar is off screen: when the keyboard is
/// hidden, or when a hardware keyboard is in use and the bar is turned off.
/// Without it, the keyboard shortcut would be the only way to open the
/// switcher.
final class FloatingSwitcher: UIView {

    static let size: CGFloat = 44

    let button = SwitcherButton()
    private let capsule = KeyBar.makeCapsule()

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Dark, like the key bar, since it sits over the terminal, which is dark.
        overrideUserInterfaceStyle = .dark
        tintColor = Accent.custom

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
        button.capsuleLaidOut()
    }
}
