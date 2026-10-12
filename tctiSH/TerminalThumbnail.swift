//
//  TerminalThumbnail.swift
//  A small picture of what a terminal is showing, for the switcher's cards.
//
//  Copyright © 2026 Ara Adkins.
//

import SwiftTerm
import UIKit

/// Draws a terminal's screen, as it currently appears, at a smaller size.
///
/// SwiftTerm has no API for this, but it draws with CoreGraphics in `draw(_:)`,
/// into whatever graphics context is current. Calling `draw(_:)` inside an
/// image renderer whose context is scaled down makes CoreText lay the text out
/// at the smaller size, so it stays sharp. The terminal is unaffected: its rows
/// and columns don't change, and nothing reflows.
///
/// This works only while the view draws with CoreGraphics. When it renders with
/// Metal, `draw(_:)` returns without drawing.
enum TerminalThumbnail {

    /// Draws `terminal` scaled to `width` points wide, at `scale` pixels per
    /// point, or returns nil if either has no size.
    static func render(_ terminal: TerminalView, width: CGFloat, scale: CGFloat) -> UIImage? {
        let bounds = terminal.bounds
        guard bounds.width > 0, bounds.height > 0, width > 0 else { return nil }

        let factor = width / bounds.width
        let size = CGSize(width: width, height: (bounds.height * factor).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.scaleBy(x: factor, y: factor)

            // The view is a scroll view and draws in content coordinates: on iOS, SwiftTerm chooses
            // which rows to draw from the content offset, and draws each row at its position in the
            // buffer, measured from the top of the content. Translating by the bounds' origin,
            // which is the content offset, moves the visible rows to the top of the picture, where
            // they appear on screen.
            cg.translateBy(x: -bounds.minX, y: -bounds.minY)

            terminal.draw(bounds)
        }
    }

    /// The average color of `image`, composited over `background` so that any
    /// transparent areas count as `background`. Returns `background` if the
    /// image can't be read.
    static func averageColor(of image: UIImage, over background: UIColor) -> UIColor {
        guard let picture = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return background }

        // Draw the image into a 16-by-16 bitmap first. High-quality downsampling does most of the
        // averaging, and leaves only 256 pixels to sum.
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let cg = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            cg.interpolationQuality = .high
            cg.setFillColor(background.cgColor)
            cg.fill(rect)
            cg.draw(picture, in: rect)
            return true
        }
        guard drawn else { return background }

        var sums = [0, 0, 0]
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                sums[channel] += Int(pixels[pixel + channel])
            }
        }
        let count = CGFloat(side * side * 255)
        return UIColor(
            red: CGFloat(sums[0]) / count, green: CGFloat(sums[1]) / count,
            blue: CGFloat(sums[2]) / count, alpha: 1)
    }
}
