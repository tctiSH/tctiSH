//
//  ThemePreview.swift
//  A theme drawn small: a few lines of a terminal in its colors, and a swatch
//  for a list row.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// A few lines of terminal content in a theme's colors: a prompt, ls and git
/// output, every ANSI color as text and as a block, and a selection and the
/// cursor.
///
/// Drawn as text so the selection and the cursor can be shown without anything
/// selected or focused. Tapping or clicking a part of it reports the color that
/// part is drawn in; see `onTap`.
final class ThemePreview: UIView {

    /// Called with the color under a tap or a click: the fill of a block, the
    /// selection or the cursor; otherwise the color of the text there; or,
    /// between and around the text, the background.
    var onTap: ((TerminalTheme.Role) -> Void)?

    var theme: TerminalTheme {
        didSet {
            accessibilityValue = theme.title
            guard theme.colors != oldValue.colors else { return }
            render()
        }
    }

    /// Whether to show only the colors, the selection and the cursor, for where
    /// there's little height to spare.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            render()
        }
    }

    private let text = UILabel()

    /// Where each run's characters are in the text, and the color a tap on them
    /// reports.
    private var tapRoles: [(range: NSRange, role: TerminalTheme.Role)] = []

    private let font: UIFont
    private let boldFont: UIFont

    private static let padding: CGFloat = 12

    /// Shows `theme` in Menlo at `textSize` points: 12 for Settings, larger for
    /// Quick Look's whole screen.
    init(theme: TerminalTheme, textSize: CGFloat = 12) {
        self.theme = theme
        font =
            UIFont(name: "Menlo-Regular", size: textSize)
            ?? .monospacedSystemFont(ofSize: textSize, weight: .regular)
        boldFont =
            UIFont(name: "Menlo-Bold", size: textSize)
            ?? .monospacedSystemFont(ofSize: textSize, weight: .bold)
        super.init(frame: .zero)

        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = TerminalTheme.edge.cgColor
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Preview"
        accessibilityValue = theme.title

        text.numberOfLines = 0
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            text.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Self.padding),
        ])

        render()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; previews are built in code")
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        onTap?(role(at: tap.location(in: text)))
    }

    /// The color drawn at `point`, in the label's coordinates, found by laying
    /// the label's text out again with TextKit, as the label does.
    private func role(at point: CGPoint) -> TerminalTheme.Role {
        guard let attributed = text.attributedText, text.bounds.contains(point) else {
            return .background
        }

        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: text.bounds.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = text.numberOfLines
        container.lineBreakMode = text.lineBreakMode
        layout.addTextContainer(container)

        // The nearest glyph, which is only the one tapped if the tap is within it: past the end of
        // a line is the background.
        let glyph = layout.glyphIndex(for: point, in: container)
        let bounds = layout.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard bounds.contains(point) else { return .background }

        let index = layout.characterIndexForGlyph(at: glyph)
        return tapRoles.first { NSLocationInRange(index, $0.range) }?.role ?? .background
    }

    /// A run of text, in one of the theme's colors, on another or on the
    /// background.
    private struct Run {
        var text: String
        var color: TerminalTheme.Role = .foreground
        var fill: TerminalTheme.Role?
        var bold = false
    }

    /// The prompt, as tctiSH's shell integration writes it: bold magenta, which
    /// the terminal draws in the bright version.
    private static let prompt = Run(text: "_~# ", color: .ansi(13), bold: true)

    /// The lines, no wider than 36 columns so they fit on the narrowest phone.
    private static let lines: [[Run]] = [
        [prompt, Run(text: "ls")],
        [
            Run(text: "bin", color: .ansi(4)), Run(text: "  docs", color: .ansi(4)),
            Run(text: "  notes.txt  "), Run(text: "run.sh", color: .ansi(2)),
            Run(text: "  lib", color: .ansi(6)),
        ],
        [prompt, Run(text: "git diff --stat")],
        [
            Run(text: " theme.json | 6 "), Run(text: "+++", color: .ansi(2)),
            Run(text: "---", color: .ansi(1)),
        ],
        TerminalTheme.Role.normal.map { Run(text: " Aa ", color: $0) },
        TerminalTheme.Role.bright.map { Run(text: " Aa ", color: $0) },
        TerminalTheme.Role.normal.map { Run(text: "    ", fill: $0) },
        TerminalTheme.Role.bright.map { Run(text: "    ", fill: $0) },
        [
            prompt, Run(text: "selected", color: .selectedText, fill: .selection),
            Run(text: " tex"), Run(text: "t", color: .cursorText, fill: .cursor),
        ],
    ]

    /// The lines kept when compact: the colors as text, and the selection and
    /// the cursor.
    private static let compactLines = [lines[4], lines[5], lines[8]]

    private func render() {
        backgroundColor = theme.background.uiColor

        let lines = isCompact ? Self.compactLines : Self.lines
        let preview = NSMutableAttributedString()
        tapRoles = []
        for (index, line) in lines.enumerated() {
            for run in line {
                // A space with nothing behind it shows the background, so it reports that.
                var offset = 0
                for character in run.text {
                    let length = String(character).utf16.count
                    let role = run.fill ?? (character == " " ? .background : run.color)
                    tapRoles.append(
                        (NSRange(location: preview.length + offset, length: length), role))
                    offset += length
                }

                var attributes: [NSAttributedString.Key: Any] = [
                    .font: run.bold ? boldFont : font,
                    .foregroundColor: theme[run.color].uiColor,
                ]
                if let fill = run.fill {
                    attributes[.backgroundColor] = theme[fill].uiColor
                }
                preview.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            if index < lines.count - 1 {
                preview.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
        }
        text.attributedText = preview
    }
}

extension TerminalTheme {

    /// The faint edge round a theme's preview and swatch, so that a background
    /// like the list's still has one.
    static let edge = UIColor(white: 0.5, alpha: 0.4)

    /// A small picture of the theme for a list row: its background, with a line
    /// of its text color and a dot of each of its six hues. About as wide as
    /// the rows' symbols, in whose column it's drawn.
    var swatch: UIImage {
        let size = CGSize(width: 24, height: 16)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            drawSwatch(in: CGRect(origin: .zero, size: size))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Draws the swatch into the current context, filling `rect`, which should
    /// be 3:2 as the swatch is. Larger, it's the thumbnail of a theme file.
    func drawSwatch(in rect: CGRect) {
        // Laid out on the 24 by 16 points of a list row's swatch, and scaled.
        let scale = rect.width / 24
        func place(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: rect.minX + x * scale, y: rect.minY + y * scale, width: width * scale,
                height: height * scale)
        }

        let card = UIBezierPath(
            roundedRect: rect.insetBy(dx: 0.25 * scale, dy: 0.25 * scale),
            cornerRadius: 4 * scale)
        background.uiColor.setFill()
        card.fill()
        Self.edge.setStroke()
        card.lineWidth = 0.5 * scale
        card.stroke()

        foreground.uiColor.setFill()
        UIBezierPath(roundedRect: place(3, 4, 11, 2), cornerRadius: 1 * scale).fill()

        for hue in 1...6 {
            ansi[hue].uiColor.setFill()
            UIBezierPath(ovalIn: place(3 + CGFloat(hue - 1) * 3.1, 9.5, 2.4, 2.4)).fill()
        }
    }
}
