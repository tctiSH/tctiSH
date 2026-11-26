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
/// Drawn from a copy of the rows on screen, not by SwiftTerm. SwiftTerm draws
/// what it last prepared for the screen, and it stops preparing while a
/// terminal isn't in a window, which most of the switcher's TTYs aren't. Text
/// is laid out at the smaller size, so it stays sharp, and the terminal is
/// unaffected: its rows and columns don't change, and nothing reflows.
///
/// Only text, bold and colors are drawn, in the colors SwiftTerm picks with its
/// default settings. Underlines, italics, dimming, the cursor and the selection
/// don't show at this size, and images aren't in the copy of the screen.
enum TerminalThumbnail {

    /// Draws `terminal` scaled to `width` points wide, at `scale` pixels per
    /// point, or returns nil if either has no size or there is no terminal to
    /// draw.
    static func render(_ terminal: TerminalView, width: CGFloat, scale: CGFloat) -> UIImage? {
        let bounds = terminal.bounds
        guard bounds.width > 0, bounds.height > 0, width > 0,
            let screen = terminal.terminalContentSnapshot(region: .viewport),
            screen.dimensions.cols > 0, screen.dimensions.rows > 0
        else { return nil }

        let factor = width / bounds.width
        let size = CGSize(width: width, height: (bounds.height * factor).rounded())

        // SwiftTerm doesn't make its cell size public, but the frame that fits the terminal exactly
        // is that size times the columns and rows.
        let grid = terminal.getOptimalFrameSize().size
        let cell = CGSize(
            width: grid.width / CGFloat(screen.dimensions.cols),
            height: grid.height / CGFloat(screen.dimensions.rows))
        let colors = Colors(screen: screen, terminal: terminal)
        let regular = Font(terminal.font, cellWidth: cell.width)
        let bold = Font(
            UIFont(
                descriptor: terminal.font.fontDescriptor.withSymbolicTraits(.traitBold)
                    ?? terminal.font.fontDescriptor,
                size: terminal.font.pointSize),
            cellWidth: cell.width)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(colors.background.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.scaleBy(x: factor, y: factor)

            for (index, row) in screen.rows.enumerated() {
                let top = CGFloat(index) * cell.height
                for run in runs(of: row) {
                    let style = run.attribute.style
                    let colored = colors.colors(of: run.attribute)

                    let left = CGFloat(run.columns.lowerBound) * cell.width
                    if let background = colored.background {
                        cg.setFillColor(background.cgColor)
                        cg.fill(
                            CGRect(
                                x: left, y: top, width: CGFloat(run.columns.count) * cell.width,
                                height: cell.height))
                    }
                    guard !style.contains(.invisible), run.text.contains(where: { $0 != " " })
                    else { continue }
                    let font = style.contains(.bold) ? bold : regular
                    NSAttributedString(
                        string: run.text,
                        attributes: [
                            .font: font.font, .kern: font.kern,
                            .foregroundColor: colored.foreground,
                        ]
                    ).draw(at: CGPoint(x: left, y: top))
                }
            }
        }
    }

    /// A font, and the spacing that puts its characters a cell apart. SwiftTerm
    /// rounds a cell's width to whole pixels, so a cell can be a little wider
    /// or narrower than a character.
    private struct Font {
        let font: UIFont
        let kern: CGFloat

        init(_ font: UIFont, cellWidth: CGFloat) {
            self.font = font
            kern = cellWidth - ("W" as NSString).size(withAttributes: [.font: font]).width
        }
    }

    /// Neighboring characters of a row with the same attribute: the columns
    /// they take, and their text.
    private struct Run {
        var attribute: Attribute
        var columns: Range<Int>
        var text: String
        var isWide: Bool
    }

    /// The runs of characters in `row` with the same attribute. Each wide
    /// character is a separate run, drawn at its column: its glyph comes from
    /// another font, whose characters aren't two cells wide.
    private static func runs(of row: TerminalContentRowSnapshot) -> [Run] {
        var runs: [Run] = []
        for (column, text, cell) in row.characters {
            let isWide = cell.width == 2
            if !isWide, let last = runs.last, !last.isWide, last.attribute == cell.attribute {
                runs[runs.count - 1].columns = last.columns.lowerBound..<column + 1
                runs[runs.count - 1].text += text
            } else {
                runs.append(
                    Run(
                        attribute: cell.attribute, columns: column..<column + (isWide ? 2 : 1),
                        text: text, isWide: isWide))
            }
        }
        return runs
    }

    /// The colors the terminal draws cells in.
    private struct Colors {
        let foreground: UIColor
        let background: UIColor
        let palette: [UIColor]

        init(screen: TerminalContentSnapshot, terminal: TerminalView) {
            foreground = terminal.nativeForegroundColor
            background = terminal.nativeBackgroundColor
            palette = screen.palette.map {
                UIColor(
                    red: CGFloat($0.red) / 65535, green: CGFloat($0.green) / 65535,
                    blue: CGFloat($0.blue) / 65535, alpha: 1)
            }
        }

        /// The colors of text with `attribute`, and of the cells behind it, or
        /// nil for the default background, which is already there.
        ///
        /// As in SwiftTerm, inverse text swaps the attribute's colors before
        /// they are looked up, and bold text in the first eight colors is drawn
        /// in the bright eight.
        func colors(of attribute: Attribute) -> (foreground: UIColor, background: UIColor?) {
            var foreground = attribute.fg
            var background = attribute.bg
            if attribute.style.contains(.inverse) {
                swap(&foreground, &background)
                if foreground == .defaultColor { foreground = .defaultInvertedColor }
                if background == .defaultColor { background = .defaultInvertedColor }
            }
            let bold = attribute.style.contains(.bold)
            return (
                color(foreground, foreground: true, bold: bold) ?? self.foreground,
                color(background, foreground: false, bold: false)
            )
        }

        private func color(_ color: Attribute.Color, foreground isForeground: Bool, bold: Bool)
            -> UIColor?
        {
            switch color {
            case .defaultColor:
                return isForeground ? foreground : nil
            case .defaultInvertedColor:
                return isForeground ? background : foreground
            case .ansi256(let code):
                let index = Int(code) + (isForeground && bold && code < 8 ? 8 : 0)
                return index < palette.count ? palette[index] : (isForeground ? foreground : nil)
            case .trueColor(let red, let green, let blue):
                return UIColor(
                    red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255,
                    alpha: 1)
            }
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
