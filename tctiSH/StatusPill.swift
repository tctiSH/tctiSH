//
//  StatusPill.swift
//  Floating status indicator shown over the terminal.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// A floating capsule: a short message, and an indicator beside it.
///
/// Sits in the top right, over the terminal, for things the user should know
/// about but must not be interrupted by. Swipeable away always; tappable only
/// when given something to do.
final class StatusPill: UIView {

    private enum Metric {
        static let height: CGFloat = 34
        static let leadingInset: CGFloat = 14
        static let trailingInset: CGFloat = 9
        static let spacing: CGFloat = 9
        static let dial: CGFloat = 18
        static let margin: CGFloat = 10
    }

    /// The message shown to the left of the dial.
    var title: String {
        get { label.text ?? "" }
        set {
            guard label.text != newValue else { return }
            label.text = newValue
            accessibilityLabel = newValue

            // The capsule is sized by its content, so a new message changes its width. Animate that
            // rather than letting it jump.
            UIView.animate(withDuration: 0.25) {
                self.superview?.layoutIfNeeded()
            }
        }
    }

    /// Colour of the label and the dial.
    ///
    /// Defaults to `.label`, which follows the appearance the pill picked from
    /// its backdrop. Set it to say something the message alone can't.
    var tint: UIColor = .label {
        didSet {
            guard tint != oldValue else { return }
            applyTint()
        }
    }

    /// What to do when the pill is tapped, or nil for one that isn't tappable.
    var onTap: (() -> Void)? {
        didSet {
            accessibilityTraits = onTap != nil ? .button : .updatesFrequently
        }
    }

    /// Called when the user swipes the pill away.
    ///
    /// Every pill can be dismissed this way, whether or not it does anything
    /// else. Status the user can't get rid of stops being status and becomes
    /// clutter.
    var onSwipeAway: (() -> Void)?

    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let label = UILabel()
    private let dial = ProgressDial()

    /// Shown in the dial's place for status that isn't progress.
    private let symbolView = UIImageView()

    /// Holds this pill below the top of the safe area.
    ///
    /// Exposed because pills stack, and a stack has to close up when one of its
    /// members leaves.
    private(set) var topConstraint: NSLayoutConstraint!

    /// How tall a pill is, the gap between stacked ones, and how far the first
    /// sits from the top. Public so a stack can be laid out without guessing.
    static var preferredHeight: CGFloat { Metric.height }
    static var stackSpacing: CGFloat { 8 }
    static var topMargin: CGFloat { Metric.margin }

    // MARK: - Construction

    /// Builds a pill and floats it in the top right of `parent`.
    ///
    /// `backdrop` is whatever the pill will be sitting on (the terminal's
    /// background, in practice) and decides whether it dresses light or dark.
    /// `topOffset` is where it sits in the stack; see `StatusPresenter`.
    @discardableResult
    static func show(
        in parent: UIView, title: String, over backdrop: UIColor,
        topOffset: CGFloat = Metric.margin
    ) -> StatusPill {
        let pill = StatusPill(title: title)
        pill.overrideUserInterfaceStyle = style(toSitOn: backdrop)
        pill.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(pill)

        let top = pill.topAnchor.constraint(
            equalTo: parent.safeAreaLayoutGuide.topAnchor,
            constant: topOffset)
        pill.topConstraint = top

        NSLayoutConstraint.activate([
            top,
            pill.trailingAnchor.constraint(
                equalTo: parent.safeAreaLayoutGuide.trailingAnchor,
                constant: -Metric.margin),
            pill.heightAnchor.constraint(equalToConstant: Metric.height),

            // Never let a long message crowd the terminal out.
            pill.leadingAnchor.constraint(
                greaterThanOrEqualTo: parent.safeAreaLayoutGuide.leadingAnchor,
                constant: Metric.margin),
        ])

        pill.alpha = 0
        pill.transform = CGAffineTransform(translationX: 0, y: -10).scaledBy(x: 0.92, y: 0.92)
        parent.layoutIfNeeded()

        UIView.animate(
            withDuration: 0.35, delay: 0,
            usingSpringWithDamping: 0.8, initialSpringVelocity: 0
        ) {
            pill.alpha = 1
            pill.transform = .identity
        }

        return pill
    }

    private init(title: String) {
        super.init(frame: .zero)

        // Purely informational: touches belong to the terminal underneath.
        isUserInteractionEnabled = false

        background.translatesAutoresizingMaskIntoConstraints = false
        background.layer.cornerRadius = Metric.height / 2
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true

        // A hairline keeps the capsule's edge legible against a terminal that might be any colour
        // the theme fancies.
        background.layer.borderWidth = 1 / UIScreen.main.scale
        background.layer.borderColor = UIColor.separator.cgColor

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        label.text = title
        label.textColor = .label
        label.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .systemFont(ofSize: 13, weight: .medium))
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        dial.translatesAutoresizingMaskIntoConstraints = false

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = .label
        symbolView.isHidden = true

        addSubview(background)
        background.contentView.addSubview(label)
        background.contentView.addSubview(dial)
        background.contentView.addSubview(symbolView)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.leadingAnchor.constraint(
                equalTo: background.contentView.leadingAnchor,
                constant: Metric.leadingInset),
            label.centerYAnchor.constraint(equalTo: background.contentView.centerYAnchor),

            dial.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: Metric.spacing),
            dial.trailingAnchor.constraint(
                equalTo: background.contentView.trailingAnchor,
                constant: -Metric.trailingInset),
            dial.centerYAnchor.constraint(equalTo: background.contentView.centerYAnchor),
            dial.widthAnchor.constraint(equalToConstant: Metric.dial),
            dial.heightAnchor.constraint(equalToConstant: Metric.dial),

            // The symbol shares the dial's slot, so the capsule is the same shape whichever is
            // showing.
            symbolView.centerXAnchor.constraint(equalTo: dial.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: dial.centerYAnchor),
            symbolView.widthAnchor.constraint(equalTo: dial.widthAnchor),
            symbolView.heightAnchor.constraint(equalTo: dial.heightAnchor),
        ])

        // Always interactive, for the swipe. A pill is small, transient and sits in a corner, so
        // the taps it costs the terminal are worth being able to get rid of it.
        isUserInteractionEnabled = true

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))

        for direction in [UISwipeGestureRecognizer.Direction.up, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe))
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }

        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = title
        accessibilityHint = "Swipe up to dismiss"

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pill: Self, _) in
            pill.refreshLayerColours()
        }
        refreshLayerColours()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusPill is built in code")
    }

    // MARK: - Progress

    /// What the dial is showing.
    enum State: Equatable {

        /// Running, with no idea how much is left. A real answer, not a
        /// fallback: a stage we cannot measure should say so by spinning rather
        /// than by inventing a number.
        case indeterminate

        /// Running, this far along, 0...1.
        case progress(Double)

        /// Done, and it worked.
        case succeeded

        /// Done, and it didn't.
        case failed

        /// Not progress at all -- a piece of status, shown as an SF Symbol.
        case symbol(String)

        /// Something is about to happen by itself, and this is how much time is
        /// left to stop it: 1 down to 0.
        ///
        /// The ring empties rather than fills.
        case countdown(Double)
    }

    /// Sets what the indicator shows.
    func setState(_ state: State, animated: Bool = true) {
        if case .symbol(let name) = state {
            symbolView.image = UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 14, weight: .semibold))
            symbolView.isHidden = false
            dial.isHidden = true
            accessibilityValue = nil
            return
        }

        symbolView.isHidden = true
        dial.isHidden = false
        dial.setState(state, animated: animated)

        switch state {
        case .indeterminate: accessibilityValue = nil
        case .progress(let fraction): accessibilityValue = "\(Int(fraction * 100)) percent"
        case .succeeded: accessibilityValue = "finished"
        case .failed: accessibilityValue = "failed"
        case .countdown: accessibilityValue = "cancel"
        case .symbol: break
        }
    }

    /// Which way a pill leaves.
    enum Exit {
        /// Retiring of its own accord: a small lift, and gone.
        case quietly
        /// Thrown out. Follows the hand.
        case up
        case right
    }

    /// Fades the pill out and removes it.
    func dismiss(after delay: TimeInterval = 0, towards exit: Exit = .quietly) {
        // Stop it responding to anything on the way out.
        isUserInteractionEnabled = false

        let leaving: CGAffineTransform
        switch exit {
        case .quietly:
            leaving = CGAffineTransform(translationX: 0, y: -6).scaledBy(x: 0.95, y: 0.95)
        case .up:
            leaving = CGAffineTransform(translationX: 0, y: -bounds.height * 1.6)
        case .right:
            leaving = CGAffineTransform(translationX: bounds.width * 1.2, y: 0)
        }

        UIView.animate(withDuration: exit == .quietly ? 0.3 : 0.22, delay: delay) {
            self.alpha = 0
            self.transform = leaving
        } completion: { _ in
            self.removeFromSuperview()
        }
    }

    @objc private func handleSwipe(_ recogniser: UISwipeGestureRecognizer) {
        dismiss(towards: recogniser.direction == .right ? .right : .up)
        onSwipeAway?()
    }

    @objc private func handleTap() {
        guard let onTap else { return }

        // A little acknowledgement, since a capsule has no pressed state.
        UIView.animate(
            withDuration: 0.08,
            animations: {
                self.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            },
            completion: { _ in
                UIView.animate(withDuration: 0.18) { self.transform = .identity }
            })

        onTap()
    }

    private func applyTint() {
        label.textColor = tint
        symbolView.tintColor = tint
        dial.tint = tint
    }

    /// CGColors don't follow the trait environment the way UIColors do, so the
    /// ones handed to layers have to be reapplied by hand.
    private func refreshLayerColours() {
        background.layer.borderColor = UIColor.separator.cgColor
        applyTint()
    }

    /// Chooses an appearance to suit what the pill is sitting on.
    ///
    /// Materials and `.label` follow the *system* appearance, which has nothing
    /// to do with the terminal's theme: a device in light mode showing a
    /// solarized-dark terminal would otherwise drop a pale capsule with black
    /// text onto a near-black background. Deciding from the backdrop's
    /// luminance instead keeps the pill in the same world as the thing behind
    /// it.
    private static func style(toSitOn backdrop: UIColor) -> UIUserInterfaceStyle {
        var luminance: CGFloat = 0
        var alpha: CGFloat = 0

        guard backdrop.getWhite(&luminance, alpha: &alpha) else {
            return .unspecified
        }

        return luminance < 0.5 ? .dark : .light
    }
}

/// A small ring that fills clockwise from the top, and marks itself when done.
private final class ProgressDial: UIView {

    private enum Metric {
        static let lineWidth: CGFloat = 2
        static let markWidth: CGFloat = 1.8
        static let spinnerSweep: CGFloat = 0.25
        static let spinDuration: CFTimeInterval = 1.1
        static let drawDuration: CFTimeInterval = 0.15
    }

    /// The unfilled remainder, always visible, so an empty dial still reads as
    /// a dial rather than as nothing at all.
    private let track = CAShapeLayer()

    /// The filled arc. Sweeps clockwise from twelve o'clock.
    private let arc = CAShapeLayer()

    /// A short arc that chases its own tail while the length is unknown.
    private let spinner = CAShapeLayer()

    /// Drawn inside the ring once the work has finished.
    private let mark = CAShapeLayer()

    private var state: State = .indeterminate

    /// Colour of everything except the track, which stays a background detail.
    var tint: UIColor = .label {
        didSet {
            guard tint != oldValue else { return }
            refreshLayerColours()
        }
    }

    typealias State = StatusPill.State

    override init(frame: CGRect) {
        super.init(frame: frame)

        for shape in [track, arc, spinner, mark] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineCap = .round
            layer.addSublayer(shape)
        }

        track.lineWidth = Metric.lineWidth
        track.lineCap = .butt
        track.strokeColor = UIColor.separator.cgColor

        arc.lineWidth = Metric.lineWidth
        arc.strokeEnd = 0
        arc.strokeColor = UIColor.label.cgColor

        spinner.lineWidth = Metric.lineWidth
        spinner.strokeEnd = Metric.spinnerSweep
        spinner.strokeColor = UIColor.label.cgColor
        spinner.isHidden = true

        mark.lineWidth = Metric.markWidth
        mark.lineJoin = .round
        mark.strokeEnd = 0
        mark.strokeColor = UIColor.label.cgColor

        // Core Animation drops animations when the app is backgrounded and does not put them back;
        // without this the spinner returns frozen.
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartSpinnerIfNeeded),
            name: UIApplication.willEnterForegroundNotification, object: nil)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (dial: Self, _) in
            dial.refreshLayerColours()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ProgressDial is built in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let side = min(bounds.width, bounds.height)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = side / 2 - Metric.lineWidth / 2

        // Starting at -pi/2 puts the seam at twelve o'clock, so the ring fills from the top the way
        // a clock face would.
        let ring = UIBezierPath(
            arcCenter: centre, radius: radius,
            startAngle: -.pi / 2, endAngle: .pi * 1.5,
            clockwise: true
        ).cgPath
        track.path = ring
        arc.path = ring
        spinner.path = ring
        mark.path = markPath(for: state, centre: centre, side: side)

        for shape in [track, arc, spinner, mark] {
            shape.frame = bounds
        }
    }

    /// The tick or cross drawn inside the ring, sized from the dial.
    private func markPath(for state: State, centre: CGPoint, side: CGFloat) -> CGPath? {
        let point = { (x: CGFloat, y: CGFloat) in
            CGPoint(x: centre.x + x * side, y: centre.y + y * side)
        }

        let path = UIBezierPath()

        switch state {
        case .succeeded:
            path.move(to: point(-0.178, 0.011))
            path.addLine(to: point(-0.056, 0.144))
            path.addLine(to: point(0.189, -0.156))

        case .failed, .countdown:
            path.move(to: point(-0.14, -0.14))
            path.addLine(to: point(0.14, 0.14))
            path.move(to: point(0.14, -0.14))
            path.addLine(to: point(-0.14, 0.14))

        case .indeterminate, .progress, .symbol:
            return nil
        }

        return path.cgPath
    }

    func setState(_ newState: State, animated: Bool) {
        let wasIndeterminate = state == .indeterminate
        state = newState

        switch newState {
        case .symbol:
            // Handled by the pill, which swaps the dial out entirely.
            break

        case .countdown(let remaining):
            showArc(wasIndeterminate: wasIndeterminate)
            setStrokeEnd(arc, to: CGFloat(min(max(remaining, 0), 1)), animated: animated)
            drawMark(animated: false)

        case .indeterminate:
            arc.isHidden = true
            mark.isHidden = true
            spinner.isHidden = false
            restartSpinnerIfNeeded()

        case .progress(let fraction):
            showArc(wasIndeterminate: wasIndeterminate)
            mark.isHidden = true
            setStrokeEnd(arc, to: CGFloat(min(max(fraction, 0), 1)), animated: animated)

        case .succeeded, .failed:
            showArc(wasIndeterminate: wasIndeterminate)

            // Complete the ring first, then draw the mark into it, so the two read as one gesture
            // rather than appearing together.
            setStrokeEnd(arc, to: 1, animated: animated)
            drawMark(animated: animated)
        }
    }

    private func showArc(wasIndeterminate: Bool) {
        spinner.isHidden = true
        spinner.removeAllAnimations()
        arc.isHidden = false

        // Coming off the spinner, start from empty rather than animating down from whatever
        // happened to be shown last.
        if wasIndeterminate {
            setStrokeEnd(arc, to: 0, animated: false)
        }
    }

    private func drawMark(animated: Bool) {
        let side = min(bounds.width, bounds.height)
        mark.path = markPath(
            for: state,
            centre: CGPoint(x: bounds.midX, y: bounds.midY),
            side: side)
        mark.isHidden = false

        guard animated else {
            setStrokeEnd(mark, to: 1, animated: false)
            return
        }

        setStrokeEnd(mark, to: 0, animated: false)

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.22
        draw.beginTime = CACurrentMediaTime() + Metric.drawDuration * 0.7
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)

        mark.strokeEnd = 1
        mark.add(draw, forKey: "draw")
    }

    private func setStrokeEnd(_ shape: CAShapeLayer, to value: CGFloat, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Metric.drawDuration)
        shape.strokeEnd = value
        CATransaction.commit()
    }

    @objc private func restartSpinnerIfNeeded() {
        guard !spinner.isHidden, spinner.animation(forKey: "spin") == nil else { return }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = Metric.spinDuration
        spin.repeatCount = .infinity
        spinner.add(spin, forKey: "spin")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restartSpinnerIfNeeded()
    }

    /// As above: layer colours don't follow the trait environment themselves.
    private func refreshLayerColours() {
        track.strokeColor = UIColor.separator.cgColor
        for shape in [arc, spinner, mark] {
            shape.strokeColor = tint.cgColor
        }
    }
}
