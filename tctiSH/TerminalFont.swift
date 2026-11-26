//
//  TerminalFont.swift
//  The font terminals draw in.
//
//  Copyright © 2026 Ara Adkins.
//

import CoreText
import UIKit

/// The font terminals draw in: the one chosen in Settings, or Menlo.
///
/// The choice is stored by PostScript name. If that font is removed, as when
/// the profile that installed it is, terminals use Menlo until it's back.
enum TerminalFont {

    static let defaultName = "Menlo-Regular"

    /// The chosen font's PostScript name, or nil for the default.
    static var chosenName: String? {
        let name = AppSetting.terminalFont.string
        return name.isEmpty ? nil : name
    }

    /// Chooses `font`, or the default for nil or Menlo.
    static func choose(_ font: UIFont?) {
        if let font, font.fontName != defaultName {
            AppSetting.terminalFont.set(font.fontName)
        } else {
            AppSetting.terminalFont.clear()
        }
    }

    /// A font's regular, bold, italic and bold italic faces, which SwiftTerm
    /// takes as a set.
    struct Faces {
        let regular: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
    }

    /// The faces terminals draw in at `size` points, without ligatures if
    /// they're turned off.
    static func faces(size: CGFloat) -> Faces {
        let font = inUse(size: size)
        let ligatures = AppSetting.terminalLigatures.bool

        // Found by the same traits, and in the same order, as SwiftTerm finds them from one font.
        // Each is given the ligature setting here, so it doesn't depend on SwiftTerm carrying it
        // over.
        func face(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont? {
            let descriptor =
                traits.isEmpty
                ? font.fontDescriptor : font.fontDescriptor.withSymbolicTraits(traits)
            return descriptor.map { UIFont(descriptor: $0, size: 0) }
                .map { ligatures ? $0 : withoutLigatures($0) }
        }
        let regular = face([]) ?? font
        let bold = face(.traitBold) ?? regular
        let italic = face(.traitItalic) ?? regular
        let boldItalic =
            face([.traitBold, .traitItalic]) ?? (italic != regular ? italic : bold)
        return Faces(regular: regular, bold: bold, italic: italic, boldItalic: boldItalic)
    }

    /// The font in use at `size` points: the chosen one, or Menlo if nothing is
    /// chosen or the chosen font isn't installed.
    private static func inUse(size: CGFloat) -> UIFont {
        if let name = chosenName, let font = UIFont(name: name, size: size) {
            return font
        }
        return UIFont(name: defaultName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Whether `a` and `b` draw text the same: the same face and size, with the
    /// same ligatures.
    static func isSame(_ a: UIFont, _ b: UIFont) -> Bool {
        a.fontName == b.fontName && a.pointSize == b.pointSize
            && a.fontDescriptor.fontAttributes[.featureSettings] as? NSArray
                == b.fontDescriptor.fontAttributes[.featureSettings] as? NSArray
    }

    // MARK: For Settings

    /// The family name of the font in use.
    static var familyName: String {
        inUse(size: 12).familyName
    }

    /// Menlo's family name.
    static var defaultFamilyName: String {
        UIFont(name: defaultName, size: 12)?.familyName ?? "Menlo"
    }

    /// The chosen PostScript name if that font isn't installed, or nil.
    static var missingName: String? {
        chosenName.flatMap { UIFont(name: $0, size: 12) == nil ? $0 : nil }
    }

    /// The monospaced font families on the device, each in its regular face,
    /// sorted by name.
    ///
    /// Measured, since some monospaced fonts don't set the monospaced trait.
    static var monospaced: [UIFont] {
        UIFont.familyNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { family in
                let descriptor = UIFontDescriptor(fontAttributes: [
                    .family: family,
                    .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.regular],
                ])
                let font = UIFont(descriptor: descriptor, size: 12)
                // A family that can't be matched comes back as another one.
                return font.familyName == family && isMonospaced(font) ? font : nil
            }
    }

    /// Whether `font` has narrow, wide and in-between characters, all the same
    /// width.
    private static func isMonospaced(_ font: UIFont) -> Bool {
        var characters = Array("iWm0 .|_".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard
            CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count)
        else { return false }

        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, glyphs, &advances, glyphs.count)
        let widths = advances.map(\.width)
        guard let narrowest = widths.min(), let widest = widths.max() else { return false }
        return narrowest > 0 && widest - narrowest < 0.01
    }

    // MARK: Ligatures

    /// Whether the font in use has ligatures, so that turning them off changes
    /// anything.
    static var hasLigatures: Bool {
        let font = inUse(size: 12)
        return glyphs(of: ligatureSample, in: font)
            != glyphs(of: ligatureSample, in: withoutLigatures(font))
    }

    /// Character sequences that coding fonts join.
    private static let ligatureSample = "-> => != <= >= <=> === :: </ /> www"

    /// Settings that turn off the OpenType features that join characters: the
    /// standard, contextual and discretionary ligatures, and the contextual
    /// alternates most coding fonts draw theirs with.
    private static let ligaturesOff: [[String: Any]] = ["liga", "clig", "dlig", "calt"].map {
        [kCTFontOpenTypeFeatureTag as String: $0, kCTFontOpenTypeFeatureValue as String: 0]
    }

    /// `font` with its ligatures turned off.
    private static func withoutLigatures(_ font: UIFont) -> UIFont {
        UIFont(
            descriptor: font.fontDescriptor.addingAttributes([.featureSettings: ligaturesOff]),
            size: 0)
    }

    /// The glyphs `font` draws `text` with.
    private static func glyphs(of text: String, in font: UIFont) -> [CGGlyph] {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        return (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).flatMap { run in
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            return glyphs
        }
    }
}
