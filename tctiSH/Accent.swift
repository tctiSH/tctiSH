//
//  Accent.swift
//  The app's accent color, as chosen in Settings > Appearance.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// The accent color that tints tctiSH's icons, buttons and highlights.
///
/// Kept as Display P3 components rather than as sRGB or hex, so that a color
/// picked from beyond sRGB, which the picker's P3 sliders allow, comes back as
/// it was chosen. Unset, it's the system's tint.
enum Accent {

    /// Posted on the main queue when the accent changes.
    static let didChange = Notification.Name("io.ara.tctish.accentDidChange")

    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)

    /// The chosen color, or nil for the system's.
    static var custom: UIColor? {
        let components = AppSetting.accentColor.doubles
        guard components.count == 3 else { return nil }
        return UIColor(
            displayP3Red: components[0], green: components[1], blue: components[2], alpha: 1)
    }

    /// The color to paint with.
    static var color: UIColor { custom ?? .systemBlue }

    /// Whether two colors are the same, by their Display P3 components.
    static func same(_ a: UIColor?, _ b: UIColor?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let (first, second) = (p3Components(a), p3Components(b))
        guard let first, let second else { return a == b }
        return zip(first, second).allSatisfy { abs($0 - $1) < 0.001 }
    }

    private static func p3Components(_ color: UIColor) -> [Double]? {
        guard let space = displayP3,
            let components = color.cgColor
                .converted(to: space, intent: .defaultIntent, options: nil)?.components,
            components.count >= 3
        else { return nil }
        return components.prefix(3).map(Double.init)
    }

    /// What to draw on a fill of the accent, such as a lit modifier key: white,
    /// as on the system's own blue, unless the accent is light enough that
    /// black reads better.
    static var foreground: UIColor {
        luminance(of: color) > darkTextAbove ? .black : .white
    }

    /// The relative luminance above which text on the accent turns black.
    ///
    /// Higher than the strict crossing point, where black and white contrast
    /// equally, which is low enough to turn the system's blue to black text.
    private static let darkTextAbove = 0.45

    /// Relative luminance, as WCAG measures it, from linear sRGB. Extended
    /// sRGB, so that a P3 color beyond sRGB is measured for what it is.
    private static func luminance(of color: UIColor) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)

        func linear(_ component: CGFloat) -> Double {
            let c = max(Double(component), 0)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Chooses a color, or with nil goes back to the system's, and paints
    /// everything with it straight away.
    static func set(_ color: UIColor?) {
        if let color, let space = displayP3,
            let components = color.cgColor
                .converted(to: space, intent: .defaultIntent, options: nil)?.components,
            components.count >= 3
        {
            AppSetting.accentColor.set(components.prefix(3).map { min(max(Double($0), 0), 1) })
        } else {
            AppSetting.accentColor.clear()
        }

        apply()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Tints the app's window, which is inhereited by the terminal, Settings,
    /// alerts and menus. The key bar lives in the keyboard's window rather than
    /// this, so it follows `didChange` itself.
    static func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            (scene.delegate as? SceneDelegate)?.window?.tintColor = custom
        }
    }
}
