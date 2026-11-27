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
/// Only text, icons, bold and colors are drawn, in the colors SwiftTerm picks
/// with its default settings. Underlines, italics, dimming, the cursor and the
/// selection don't show at this size, and images aren't in the copy of the
/// screen.
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

        let cell = terminal.cellSize
        let colors = Colors(screen: screen, terminal: terminal)
        let icons = Icons(terminal: terminal, cell: cell)
        let regular = Font(terminal.font, cellWidth: cell.width)
        let bold = Font(
            TerminalFont.faces(size: terminal.font.pointSize).bold, cellWidth: cell.width)

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
                for run in runs(of: row, icons: icons) {
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
                    if case .icon(let placement) = run.kind {
                        icons?.draw(
                            run.text, placement: placement, color: colored.foreground,
                            at: CGPoint(x: left, y: top), in: cg)
                        continue
                    }
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
        enum Kind: Equatable {
            case text
            case wide

            /// A Nerd Font icon the terminal's font lacks, and how it's placed.
            case icon(TerminalGlyphPlacementPolicy.Placement)
        }

        var attribute: Attribute
        var columns: Range<Int>
        var text: String
        var kind: Kind
    }

    /// The runs of characters in `row` with the same attribute. Each wide
    /// character is a separate run, drawn at its column: its glyph comes from
    /// another font, whose characters aren't two cells wide. So is each Nerd
    /// Font icon the terminal's font lacks, which is fitted to its cell.
    private static func runs(of row: TerminalContentRowSnapshot, icons: Icons?) -> [Run] {
        var runs: [Run] = []
        for (column, text, cell) in row.characters {
            let kind: Run.Kind =
                if cell.width == 2 {
                    .wide
                } else if let placement = icons?.placement(of: text) {
                    .icon(placement)
                } else {
                    .text
                }
            if kind == .text, let last = runs.last, last.kind == .text,
                last.attribute == cell.attribute
            {
                runs[runs.count - 1].columns = last.columns.lowerBound..<column + 1
                runs[runs.count - 1].text += text
            } else {
                runs.append(
                    Run(
                        attribute: cell.attribute,
                        columns: column..<column + (kind == .wide ? 2 : 1), text: text, kind: kind
                    ))
            }
        }
        return runs
    }

    /// Draws the Nerd Font icons that the terminal's font lacks, placed in
    /// their cells the same way SwiftTerm places them. An icon is centered and
    /// scaled down to fit, no taller than the font's ascent. A Powerline shape
    /// is stretched to fill the cell, so that neighboring shapes join up.
    private struct Icons {
        let fallback: NerdFontFallback
        let terminalFont: UIFont
        let font: CTFont
        let cell: CGSize

        init?(terminal: TerminalView, cell: CGSize) {
            guard let fallback = NerdFontFallback.shared,
                let font = fallback.fallbackFont(forPointSize: terminal.font.pointSize)
            else { return nil }
            self.fallback = fallback
            terminalFont = terminal.font
            self.font = font
            self.cell = cell
        }

        /// How `character` is placed, or nil if it isn't a Nerd Font icon the
        /// terminal's font lacks.
        func placement(of character: String) -> TerminalGlyphPlacementPolicy.Placement? {
            guard let scalar = Self.baseScalar(of: character),
                let policy = fallback.placementPolicy(for: scalar)
            else { return nil }
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let lacks = !CTFontGetGlyphsForCharacters(
                terminalFont as CTFont, &units, &glyphs, units.count)
            return lacks ? policy.placement : nil
        }

        /// The scalar SwiftTerm asks about: the character's only one, or its
        /// first when the other is a variation selector.
        private static func baseScalar(of character: String) -> Unicode.Scalar? {
            let scalars = Array(character.unicodeScalars)
            switch scalars.count {
            case 1: return scalars[0]
            case 2 where scalars[1].properties.isVariationSelector: return scalars[0]
            default: return nil
            }
        }

        func draw(
            _ character: String, placement: TerminalGlyphPlacementPolicy.Placement,
            color: UIColor, at origin: CGPoint, in cg: CGContext
        ) {
            guard let scalar = Self.baseScalar(of: character) else { return }
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) else { return }
            let ink = CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, nil, 1)
            guard ink.width > 0, ink.height > 0 else { return }

            var scaleX = cell.width / ink.width
            var scaleY = cell.height / ink.height
            if placement != .stretch {
                let height = min(cell.height, terminalFont.ascender)
                scaleX = min(scaleX, height / ink.height, 1)
                scaleY = scaleX
            }

            // Glyphs are drawn with y going up, and the image's y goes down.
            cg.saveGState()
            cg.translateBy(x: origin.x + cell.width / 2, y: origin.y + cell.height / 2)
            cg.scaleBy(x: scaleX, y: -scaleY)
            cg.translateBy(x: -ink.midX, y: -ink.midY)
            cg.textMatrix = .identity
            cg.setFillColor(color.cgColor)
            CTFontDrawGlyphs(font, glyphs, [.zero], 1, cg)
            cg.restoreGState()
        }
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
