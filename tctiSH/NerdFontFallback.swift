//
//  NerdFontFallback.swift
//  Icons for characters the terminal's font doesn't have.
//
//  Copyright © 2026 Ara Adkins.
//

import CoreText
import Foundation
import SwiftTerm

/// Supplies Nerd Font icons for characters the terminal's selected font lacks.
///
/// Prompts, file listings and editors such as Neovim use icons from Nerd Fonts,
/// which puts them in Unicode's private-use areas where no system font should
/// have anything to draw. The app bundles Nerd Fonts' "Symbols Only" font,
/// which has every icon set but no letters. SwiftTerm uses it only for
/// characters that are unavailable in the selected terminal font, so a font
/// that does have the icons will still be used.
///
/// Thread-safe: SwiftTerm may call it from its render thread, and the lock
/// guards the only state that changes.
final class NerdFontFallback: TerminalGlyphFallbackProvider, @unchecked Sendable {

    /// The instance every terminal shares, or nil if the font couldn't be
    /// loaded.
    static let shared = NerdFontFallback()

    /// Never bumped: the font and its icons are fixed when the app is built.
    let generation: UInt64 = 1

    private let descriptor: CTFontDescriptor

    /// The icons the font has. Its few standard characters, such as ⚡ and ♥,
    /// are left to the system's fonts, so they still draw as emoji.
    private let icons: CharacterSet

    private let lock = NSLock()

    /// One font per point size: SwiftTerm's caches expect the same instance
    /// each time.
    private var fonts: [CGFloat: CTFont] = [:]

    private init?() {
        guard
            let url = Bundle.main.url(forResource: "SymbolsNerdFont-Regular", withExtension: "ttf"),
            let descriptor =
                (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?
                .first
        else {
            Log.ui.fail("terminal: couldn't load the Nerd Font symbols, so icons won't show")
            return nil
        }
        self.descriptor = descriptor
        let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
        icons = (CTFontCopyCharacterSet(font) as CharacterSet).intersection(Self.privateUse)
    }

    /// Unicode's private-use areas: the one in the Basic Multilingual Plane,
    /// and planes 15 and 16.
    private static let privateUse = CharacterSet(charactersIn: "\u{E000}"..."\u{F8FF}")
        .union(CharacterSet(charactersIn: "\u{F0000}"..."\u{10FFFD}"))

    /// The Powerline shapes, which join up with their neighbors, so they fill
    /// the cell. SwiftTerm draws the common ones, and never asks for those.
    private static let powerline: ClosedRange<UInt32> = 0xE0B0...0xE0D7

    private static let icon = TerminalGlyphPlacementPolicy(placement: .icon)
    private static let shape = TerminalGlyphPlacementPolicy(placement: .stretch)

    func placementPolicy(for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        guard icons.contains(scalar) else { return nil }
        return Self.powerline.contains(scalar.value) ? Self.shape : Self.icon
    }

    func fallbackFont(forPointSize size: CGFloat) -> CTFont? {
        lock.lock()
        defer { lock.unlock() }

        if let font = fonts[size] { return font }
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        fonts[size] = font
        return font
    }
}
