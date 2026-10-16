//
//  ColorMath.swift
//  Color conversions for choosing colors by contrast.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// Converts colors between encoded sRGB, linear sRGB and OKLab, and measures
/// them as WCAG does. Used for colors derived from the theme and the accent.
enum ColorMath {

    typealias RGB = (r: Double, g: Double, b: Double)

    /// A color's linear sRGB components.
    static func linear(_ color: UIColor) -> RGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (decode(Double(r)), decode(Double(g)), decode(Double(b)))
    }

    /// The opaque color with linear sRGB components `rgb`, clamped to sRGB.
    static func color(_ rgb: RGB) -> UIColor {
        let rgb = clamped(rgb)
        return UIColor(
            red: CGFloat(encode(rgb.r)), green: CGFloat(encode(rgb.g)),
            blue: CGFloat(encode(rgb.b)), alpha: 1)
    }

    /// An encoded sRGB component in linear light. A negative one, from an
    /// extended-range color, is mirrored.
    static func decode(_ v: Double) -> Double {
        let magnitude = abs(v)
        let linear =
            magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
        return v < 0 ? -linear : linear
    }

    /// A linear component encoded as sRGB.
    static func encode(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Each component clamped to 0...1.
    static func clamped(_ rgb: RGB) -> RGB {
        (min(max(rgb.r, 0), 1), min(max(rgb.g, 0), 1), min(max(rgb.b, 0), 1))
    }

    /// Relative luminance, as WCAG defines it.
    static func luminance(_ rgb: RGB) -> Double {
        0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
    }

    /// A color's relative luminance, as WCAG defines it.
    static func luminance(of color: UIColor) -> Double {
        luminance(linear(color))
    }

    /// Linear sRGB in OKLab.
    static func oklab(_ rgb: RGB) -> (l: Double, a: Double, b: Double) {
        let l = cbrt(0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b)
        let m = cbrt(0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b)
        let s = cbrt(0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// A color's OKLab lightness, which runs from 0 for black to 1 for white,
    /// in even steps as the eye sees them.
    static func lightness(of color: UIColor) -> Double {
        oklab(linear(color)).l
    }

    /// The linear sRGB of an OKLab color, which may fall outside 0...1.
    static func fromOklab(_ lightness: Double, _ a: Double, _ b: Double) -> RGB {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    /// The opaque color of `top` laid over `base` at `alpha`, composited as
    /// UIKit does: on the encoded sRGB components, not in linear light.
    static func blend(_ top: UIColor, alpha: Double, over base: UIColor) -> UIColor {
        var (tr, tg, tb, ta): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let a = CGFloat(alpha)
        return UIColor(
            red: br + (tr - br) * a, green: bg + (tg - bg) * a, blue: bb + (tb - bb) * a,
            alpha: 1)
    }
}
