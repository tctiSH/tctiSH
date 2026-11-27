//
//  FontPreview.swift
//  A sample of the terminal font, for Settings.
//
//  Copyright © 2026 Ara Adkins.
//

import SwiftTerm
import UIKit

/// A sample of the terminal font in the terminal's colors: letters, digits,
/// punctuation, ligatures, bold and italic, and a few Nerd Font icons.
///
/// A SwiftTerm terminal draws it, so it matches the terminals, icons included.
/// It follows the font, the default size and the theme as they change. Where
/// the whole sample would take more than a third of the window's height, a
/// shorter one is shown, with lines dropped from its end if even that is too
/// tall.
final class FontPreview: UIView {

    private let terminal = LaidOutTerminal(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
    private var height: NSLayoutConstraint!

    /// The terminal's columns and rows when the sample was last written, and
    /// the window height it was fitted to, or nil if it needs writing again.
    private var written: (size: TerminalDimensions, windowHeight: CGFloat)?

    /// The font and colors last shown, so that a change to an unrelated setting
    /// doesn't redraw it.
    private var shown: (font: UIFont, colors: [ThemeColor])?

    private static let padding: CGFloat = 12

    init() {
        super.init(frame: .zero)

        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = TerminalTheme.edge.cgColor
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Font Preview"

        terminal.isUserInteractionEnabled = false
        terminal.showsVerticalScrollIndicator = false
        terminal.glyphFallbackProvider = NerdFontFallback.shared
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.didLayOut = { [weak self] in self?.fit() }
        addSubview(terminal)

        height = terminal.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            height,
        ])

        update()

        // By selector, so the observers go when the preview does.
        for name in [UserDefaults.didChangeNotification, TerminalThemes.didChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(update), name: name, object: nil)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (preview: FontPreview, _) in
            preview.update()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; previews are built in code")
    }

    /// Catches up with the font, the default size and the theme.
    ///
    /// Settings can change on any thread, and the terminal is UIKit's, so this
    /// moves to the main thread first.
    @objc private func update() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.update() }
            return
        }

        let theme = TerminalThemes.selected(for: TerminalThemes.Appearance(of: self))
        let faces = TerminalFont.faces(size: CGFloat(AppSetting.fontSize.integer))
        if let shown, TerminalFont.isSame(shown.font, faces.regular), shown.colors == theme.colors {
            return
        }
        shown = (faces.regular, theme.colors)

        terminal.useColors(of: theme)
        layer.backgroundColor = theme.background.uiColor.cgColor
        terminal.setFonts(
            normal: faces.regular, bold: faces.bold, italic: faces.italic,
            boldItalic: faces.boldItalic)
        accessibilityValue = faces.regular.familyName

        written = nil
        terminal.setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        written = nil
        terminal.setNeedsLayout()
    }

    /// Writes the sample again if the terminal's columns or rows or the
    /// window's height have changed, and makes the terminal tall enough for it.
    /// Called once SwiftTerm has fitted its columns and rows to its size.
    private func fit() {
        let windowHeight = window?.bounds.height ?? 0
        guard let size = terminal.terminalInputStateSnapshot()?.dimensions,
            size.cols > 0, size.rows > 0,
            written?.size != size || written?.windowHeight != windowHeight
        else { return }
        written = (size, windowHeight)

        // A line longer than the terminal is wide wraps onto more rows.
        func rows(of sample: [Line]) -> Int {
            sample.reduce(0) { rows, line in
                rows + max(1, (line.columns + size.cols - 1) / size.cols)
            }
        }
        let rowHeight = terminal.cellSize.height
        let fits = windowHeight == 0 ? Int.max : Int(windowHeight / 3 / rowHeight)

        // The terminal is made exactly as tall as what's written: with more lines than rows, it
        // would scroll.
        var sample = rows(of: Self.sample) <= fits ? Self.sample : Self.shortSample
        while sample.count > 1, rows(of: sample) > fits {
            sample.removeLast()
        }
        height.constant = CGFloat(rows(of: sample)) * rowHeight

        // Clears the screen and the scrollback and hides the cursor, then writes the sample.
        terminal.feed(
            text: "\u{1b}[H\u{1b}[2J\u{1b}[3J\u{1b}[?25l"
                + sample.map(\.text).joined(separator: "\r\n"))
    }

    /// A line of the sample: what's written, and how many columns it takes.
    private struct Line {
        var text = ""
        var columns = 0

        /// `parts` in turn, each with its SGR parameters.
        init(_ parts: (String, String)...) {
            for (characters, style) in parts {
                text += "\u{1b}[\(style)m\(characters)\u{1b}[0m"
                columns += characters.count
            }
        }
    }

    private static let ligatures = Line(("-> => != >= <=> === :: </> www", "32"))

    // A folder, a file, a terminal, a search, a gear, lazy.nvim's sleep icon, Linux, Apple, Python,
    // Rust and Vim.
    private static let icons = Line(
        ("\u{F07B} \u{F15B} \u{F120} ", "34"), ("\u{F002} \u{F013} \u{F04B2} ", "36"),
        ("\u{F17C} \u{F179} ", "0"), ("\u{E606} ", "33"), ("\u{E7A8} ", "31"),
        ("\u{E62B}", "32"))

    private static let sample = [
        Line(("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "0")),
        Line(("abcdefghijklmnopqrstuvwxyz", "0")),
        Line(("0123456789", "33"), (" ", "0"), ("O0 Il1", "36")),
        Line(("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", "35")),
        // Sequences that fonts with ligatures join.
        ligatures,
        Line(("Bold", "1"), (" ", "0"), ("Italic", "3"), (" ", "0"), ("Bold Italic", "1;3")),
        icons,
        // A prompt: a Powerline segment, then a git branch.
        Line(
            (" \u{F07B} ~/src ", "34;7"), ("\u{E0B0}", "34"), (" ", "0"),
            ("\u{E725} main", "32")),
    ]

    /// Some letters, the look-alikes, the ligatures and the icons, for where
    /// the whole sample doesn't fit.
    private static let shortSample = [
        Line(("Aa Bb Gg Qq Rr ", "0"), ("O0 Il1", "36")),
        ligatures,
        icons,
    ]
}

/// A terminal that says when it has laid out. SwiftTerm fits its columns and
/// rows to a new size in its layout.
private final class LaidOutTerminal: TerminalView {
    var didLayOut: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayOut?()
    }
}
