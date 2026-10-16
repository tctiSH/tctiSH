//
//  OverlayGlass.swift
//  Tints the glass of the bars and buttons over a terminal for its theme.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// Works out how strongly to tint the glass of the controls over a terminal:
/// the key bar, the find bar, and the follow and switcher buttons.
///
/// The glass shows the terminal's text through it, which competes with the
/// controls' labels. Tinting it with the terminal's background washes the text
/// out, and the tint's opacity is chosen so that the text stands out from the
/// background by no more than a set amount of OKLab lightness. A theme whose
/// text stands out less needs less tint.
enum OverlayGlass {

    /// How far the terminal's text may stand out from its background through
    /// dark glass, in OKLab lightness.
    static let darkShowThrough = 0.40

    /// How far the terminal's text may stand out from its background through
    /// light glass, in OKLab lightness.
    static let lightShowThrough = 0.25

    /// The tint for the glass over a terminal in `theme`, or nil for none.
    static func tint(for theme: TerminalTheme) -> UIColor? {
        let background = theme.background.uiColor
        let alpha = opacity(for: theme)
        return alpha > 0 ? background.withAlphaComponent(alpha) : nil
    }

    private static func opacity(for theme: TerminalTheme) -> CGFloat {
        if UIAccessibility.isReduceTransparencyEnabled {
            return 1
        }

        var allowed = theme.interfaceStyle == .dark ? darkShowThrough : lightShowThrough
        if UIAccessibility.isDarkerSystemColorsEnabled {
            allowed /= 2
        }

        let background = theme.background.uiColor
        let text = theme.foreground.uiColor
        let backgroundLightness = ColorMath.lightness(of: background)
        func showsThrough(_ alpha: Double) -> Double {
            abs(
                ColorMath.lightness(of: ColorMath.blend(background, alpha: alpha, over: text))
                    - backgroundLightness)
        }
        guard showsThrough(0) > allowed else { return 0 }

        // Finds the opacity by bisection, which works because the text shows through less as the
        // opacity rises.
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if showsThrough(mid) > allowed {
                low = mid
            } else {
                high = mid
            }
        }
        return CGFloat(high)
    }
}

/// A capsule of glass, or of frosted material before iOS 26, which can be
/// tinted for the theme of the terminal under it.
///
/// From iOS 26 it casts a `CapsuleShadow`. Before iOS 26 the capsule clips to
/// its shape, which would clip the shadow too.
final class GlassCapsule: UIVisualEffectView {

    private let shadow = CapsuleShadow()

    /// The color the glass is tinted with, or nil for none.
    var tint: UIColor? {
        didSet {
            guard tint != oldValue else { return }
            if #available(iOS 26.0, *) {
                effect = Self.glass(tint)
            } else {
                contentView.backgroundColor = tint
            }
        }
    }

    init() {
        if #available(iOS 26.0, *) {
            super.init(effect: Self.glass(nil))
            cornerConfiguration = .capsule()
            shadow.install(in: self)
        } else {
            super.init(effect: UIBlurEffect(style: .systemThinMaterial))
            layer.cornerCurve = .continuous
            clipsToBounds = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; the capsule is built in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if #available(iOS 26.0, *) {
            shadow.place(in: self)
        }
    }

    @available(iOS 26.0, *)
    private static func glass(_ tint: UIColor?) -> UIGlassEffect {
        let glass = UIGlassEffect()
        glass.tintColor = tint
        return glass
    }
}

/// A round button of glass, as `UIButton.Configuration.glass()` and
/// `prominentGlass()` make it, casting the same shadow as a `GlassCapsule` from
/// iOS 26, so that the two look alike side by side.
final class GlassButton: UIButton {

    private let shadow = CapsuleShadow()

    override init(frame: CGRect) {
        super.init(frame: frame)
        if #available(iOS 26.0, *) {
            shadow.install(in: self)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; the button is built in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if #available(iOS 26.0, *) {
            shadow.place(in: self)
        }
    }
}

/// The soft shadow under floating glass, as the system's glass has, so that it
/// stands off the terminal; most of all over a light theme, where the glass is
/// the color of what's behind it. A little darker over a dark theme, where it
/// shows less.
///
/// The shadow has the capsule's shape cut out of it, since the glass would let
/// it show through and look darkened from within. Its layer stays at the view's
/// origin with no size, and its shape is drawn from paths, so only the paths
/// change as the view does.
@MainActor
final class CapsuleShadow {

    /// The shadow's opacity over a dark theme and over a light one.
    private static let opacity: (dark: Float, light: Float) = (0.3, 0.2)

    private static let radius: CGFloat = 10
    private static let offset = CGSize(width: 0, height: 3)

    private let shadow = CALayer()

    /// The shadow's mask: everything outside the capsule, which is the part of
    /// the shadow that shows.
    private let outside = CAShapeLayer()

    init() {
        shadow.shadowColor = UIColor.black.cgColor
        shadow.shadowRadius = Self.radius
        shadow.shadowOffset = Self.offset
        outside.fillRule = .evenOdd
        shadow.mask = outside
    }

    /// Puts the shadow under `view`, and keeps it to the view's style.
    func install(in view: UIView) {
        view.layer.insertSublayer(shadow, at: 0)
        shade(for: view.traitCollection)
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (view: UIView, _) in
            self?.shade(for: view.traitCollection)
        }
    }

    /// Fits the shadow to `view`'s bounds, as a capsule. A path doesn't follow
    /// an animated resize by itself, so each is given the resize's animation.
    func place(in view: UIView) {
        let bounds = view.bounds
        let capsule = UIBezierPath(
            roundedRect: bounds, cornerRadius: min(bounds.width, bounds.height) / 2)
        let reach = Self.radius * 2 + abs(Self.offset.height)
        let cutOut = UIBezierPath(rect: bounds.insetBy(dx: -reach, dy: -reach))
        cutOut.append(capsule)

        let resize = view.layer.animation(forKey: "bounds.size") as? CABasicAnimation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadow.frame = .zero
        Self.set(shadow, \.shadowPath, "shadowPath", to: capsule.cgPath, as: resize)
        Self.set(outside, \.path, "path", to: cutOut.cgPath, as: resize)
        CATransaction.commit()
    }

    private static func set<Target: CALayer>(
        _ target: Target, _ path: ReferenceWritableKeyPath<Target, CGPath?>, _ key: String,
        to value: CGPath, as resize: CABasicAnimation?
    ) {
        if let animation = resize?.copy() as? CABasicAnimation {
            // UIKit's resize animates by how much the size changes, added to the final size; these
            // animate from one whole path to another.
            animation.isAdditive = false
            animation.keyPath = key
            animation.fromValue = (target.presentation() ?? target)[keyPath: path]
            animation.toValue = value
            target.add(animation, forKey: key)
        }
        target[keyPath: path] = value
    }

    private func shade(for traits: UITraitCollection) {
        shadow.shadowOpacity =
            traits.userInterfaceStyle == .dark ? Self.opacity.dark : Self.opacity.light
    }
}
