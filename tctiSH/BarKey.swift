//
//  BarKey.swift
//  The keys the key bar offers, and what each sends.
//
//  Copyright © 2026 Ara Adkins.
//

import SwiftTerm
import UIKit

// MARK: - Modifiers

/// The modifiers that can be applied to a key from the bar.
///
/// The bits are the ones xterm and the Kitty keyboard protocol both encode, one
/// more than the set, as the modifier parameter of a sequence.
struct KeyModifiers: OptionSet, Hashable {
    let rawValue: Int

    static let shift = KeyModifiers(rawValue: 1)
    static let alt = KeyModifiers(rawValue: 2)
    static let ctrl = KeyModifiers(rawValue: 4)

    /// Meta or Windows: the key Kitty and xterm call super. Not SwiftTerm's
    /// `metaModifier`, which is Alt.
    static let superKey = KeyModifiers(rawValue: 8)

    /// The modifier parameter of a CSI sequence.
    var parameter: Int { rawValue + 1 }
}

// MARK: - The keys

/// A key the bar can offer, either pinned to it or from More.
///
/// The raw values are what the pinned list is saved as, so they stay put even
/// if a key is renamed.
enum BarKey: String, CaseIterable {
    case esc, tab, menu
    case copy, paste, selectAll
    case shift, ctrl, alt
    case superKey = "super"
    case arrows
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, forwardDelete
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case f13, f14, f15, f16, f17, f18, f19, f20, f21, f22
    case keypad0, keypad1, keypad2, keypad3, keypad4, keypad5, keypad6, keypad7, keypad8, keypad9
    case tilde, pipe, slash, backslash, dash

    /// The category a key is filed under, in More and in the Pinned Keys editor
    /// alike.
    enum Group: CaseIterable {
        case keys, clipboard, modifiers, cursor, function, keypad, characters

        var title: String {
            switch self {
            case .keys: "Keys"
            case .clipboard: "Clipboard"
            case .modifiers: "Modifier Keys"
            case .cursor: "Cursor Keys"
            case .function: "Function Keys"
            case .keypad: "Keypad"
            case .characters: "Characters"
            }
        }

        var symbol: String {
            switch self {
            case .keys: "keyboard"
            case .clipboard: "clipboard"
            case .modifiers: "control"
            case .cursor: "arrow.up.and.down.and.arrow.left.and.right"
            case .function: "function"
            case .keypad: "number"
            case .characters: "textformat.characters"
            }
        }

        /// Whether More gives the group a submenu of its own.
        ///
        /// All but Esc and Tab, which are reached for often enough to be worth
        /// having to hand. Menu isn't a modifier, but is filed with them, as
        /// keyboards tend to put it beside them.
        var isSubmenu: Bool { self != .keys }
    }

    /// What a fresh install pins.
    static let defaultPinned: [BarKey] = [.esc, .ctrl, .tab, .arrows]

    /// The keys that can be pinned.
    ///
    /// Not the single arrows: the arrow pad is all four of them in one button's
    /// space, so pinning them one at a time would only crowd the bar.
    static let pinnable: [BarKey] = allCases.filter { !$0.isSingleArrow }

    var isSingleArrow: Bool {
        [.up, .down, .left, .right].contains(self)
    }

    /// The modifier this key toggles for the next keystroke, if it's one of
    /// those rather than a key that sends something itself.
    var modifier: KeyModifiers? {
        switch self {
        case .shift: .shift
        case .ctrl: .ctrl
        case .alt: .alt
        case .superKey: .superKey
        default: nil
        }
    }

    var name: String {
        switch self {
        case .esc: "Esc"
        case .tab: "Tab"
        case .menu: "Menu"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select All"
        case .shift: "Shift"
        case .ctrl: "Ctrl"
        case .alt: "Alt / Option"
        case .superKey: "Meta / Windows"
        case .arrows: "Arrow Keys"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .insert: "Insert"
        case .forwardDelete: "Forward Delete"
        case .tilde: "Tilde"
        case .pipe: "Pipe"
        case .slash: "Slash"
        case .backslash: "Backslash"
        case .dash: "Dash"
        default:
            if let digit = keypadDigit { "Keypad \(digit)" } else { rawValue.uppercased() }
        }
    }

    /// The SF Symbol it's drawn with, if it has one.
    var symbol: String? {
        switch self {
        case .esc: "escape"
        case .tab: "arrow.right.to.line.compact"
        case .menu: "contextualmenu.and.cursorarrow"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .selectAll: "selection.pin.in.out"
        case .shift: "shift"
        case .ctrl: "control"
        case .alt: "option"
        case .superKey: "command"
        case .arrows: "arrow.up.and.down.and.arrow.left.and.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .home: "arrow.left.to.line"
        case .end: "arrow.right.to.line"
        case .pageUp: "chevron.up.2"
        case .pageDown: "chevron.down.2"
        case .insert: "text.insert"
        case .forwardDelete: "delete.right"
        default: nil
        }
    }

    /// The key's picture in lists, More and the Pinned Keys editor: its symbol
    /// where it has one, and otherwise one for its kind.
    var icon: UIImage? {
        if let symbol {
            return UIImage(systemName: symbol)
        }
        if let number = functionNumber {
            return Self.functionIcon(number)
        }
        switch group {
        case .keypad: return UIImage(systemName: "equal.square")
        case .characters: return UIImage(systemName: "character.cursor.ibeam")
        default: return nil
        }
    }

    private static var functionIcons: [Int: UIImage] = [:]

    /// SF Symbols' `function`, ƒ(x), with the key's number for the x: drawn
    /// here, as there's no symbol for each key. Made once per key.
    private static func functionIcon(_ number: Int) -> UIImage {
        if let made = functionIcons[number] {
            return made
        }

        let icon = textIcon("ƒ(\(number))", font: .systemFont(ofSize: 17))
        functionIcons[number] = icon
        return icon
    }

    /// The widest a drawn icon may be: about what menus and lists keep for a
    /// symbol.
    private static let iconWidth: CGFloat = 24

    /// Text drawn as an icon, to stand where a symbol would.
    static func textIcon(_ text: String, font: UIFont) -> UIImage {
        let natural = (text as NSString).size(withAttributes: [.font: font])
        let fitted =
            natural.width > iconWidth
            ? font.withSize(font.pointSize * iconWidth / natural.width) : font

        let attributes: [NSAttributedString.Key: Any] = [
            .font: fitted, .foregroundColor: UIColor.black,
        ]
        let textWidth = (text as NSString).size(withAttributes: attributes).width

        // Enough either side for parentheses, which rise past the capitals and drop below the line.
        let room = max(-fitted.descender, fitted.ascender - fitted.capHeight)
        let size = CGSize(width: ceil(textWidth), height: ceil(fitted.capHeight + room * 2))
        let baseline = size.height - room

        return UIGraphicsImageRenderer(size: size)
            .image { _ in
                (text as NSString).draw(
                    at: CGPoint(x: (size.width - textWidth) / 2, y: baseline - fitted.ascender),
                    withAttributes: attributes)
            }
            .withRenderingMode(.alwaysTemplate)
    }

    /// Tab's symbol while Shift is on, when it sends Shift-Tab instead.
    static let backTabSymbol = "arrow.left.to.line.compact"

    /// What a key without a symbol shows instead: its character, or a short
    /// name.
    var glyph: String {
        switch self {
        case .tilde: "~"
        case .pipe: "|"
        case .slash: "/"
        case .backslash: "\\"
        case .dash: "-"
        default:
            if let digit = keypadDigit { "\(digit)" } else { name }
        }
    }

    var group: Group {
        switch self {
        case .esc, .tab: .keys
        case .copy, .paste, .selectAll: .clipboard
        case .shift, .ctrl, .alt, .superKey, .menu: .modifiers
        case .arrows, .up, .down, .left, .right, .home, .end, .pageUp, .pageDown, .insert,
            .forwardDelete:
            .cursor
        case .tilde, .pipe, .slash, .backslash, .dash: .characters
        default: keypadDigit != nil ? .keypad : .function
        }
    }

    /// Which F key this is, from 1.
    var functionNumber: Int? {
        guard rawValue.hasPrefix("f"), let number = Int(rawValue.dropFirst()) else { return nil }
        return number
    }

    var keypadDigit: Int? {
        guard rawValue.hasPrefix("keypad") else { return nil }
        return Int(rawValue.dropFirst("keypad".count))
    }

    /// The character a character key types.
    var character: Character? {
        group == .characters ? glyph.first : nil
    }

    /// The bar's key for a hardware keyboard's, where the bar has it.
    init?(hardware usage: UIKeyboardHIDUsage) {
        let fixed: [UIKeyboardHIDUsage: BarKey] = [
            .keyboardEscape: .esc, .keyboardTab: .tab, .keyboardApplication: .menu,
            .keyboardUpArrow: .up, .keyboardDownArrow: .down, .keyboardLeftArrow: .left,
            .keyboardRightArrow: .right, .keyboardHome: .home, .keyboardEnd: .end,
            .keyboardPageUp: .pageUp, .keyboardPageDown: .pageDown, .keyboardInsert: .insert,
            .keyboardDeleteForward: .forwardDelete,
            .keypad0: .keypad0, .keypad1: .keypad1, .keypad2: .keypad2, .keypad3: .keypad3,
            .keypad4: .keypad4, .keypad5: .keypad5, .keypad6: .keypad6, .keypad7: .keypad7,
            .keypad8: .keypad8, .keypad9: .keypad9,
        ]
        if let key = fixed[usage] {
            self = key
            return
        }

        // F1 to F12 are one run of usages, and F13 to F22 another.
        let raw = usage.rawValue
        let f1 = UIKeyboardHIDUsage.keyboardF1.rawValue
        let f13 = UIKeyboardHIDUsage.keyboardF13.rawValue
        let number: Int
        switch raw {
        case f1...(f1 + 11): number = raw - f1 + 1
        case f13...(f13 + 9): number = raw - f13 + 13
        default: return nil
        }
        self.init(rawValue: "f\(number)")
    }

    /// The pinned keys, in order, as saved.
    ///
    /// Anything saved that this build doesn't know is skipped, rather than
    /// losing the rest of the list over it.
    static var pinned: [BarKey] {
        get {
            // Once each, in the order first saved: a key in the list twice would take down the
            // Pinned Keys editor, whose list can't hold the same item twice.
            var seen = Set<BarKey>()
            return AppSetting.pinnedKeys.strings.compactMap(BarKey.init(rawValue:))
                .filter { seen.insert($0).inserted }
        }
        set { AppSetting.pinnedKeys.set(newValue.map(\.rawValue)) }
    }
}

// MARK: - What the keys send

/// The state of the terminal that decides how a key is encoded.
struct KeyEncodingMode {

    /// DECCKM: the cursor keys send SS3 rather than CSI.
    var applicationCursor: Bool

    /// DECKPAM: the keypad sends SS3 rather than its characters.
    var applicationKeypad: Bool

    /// The guest has turned on the Kitty keyboard protocol, at any level.
    var kitty: Bool

    /// The Kitty protocol's "report all keys as escape codes": even a plain Tab
    /// or character is sent as `CSI code u`.
    var kittyAllKeys: Bool

    /// The Kitty protocol's "report associated text", which only means
    /// something alongside reporting all keys: the text a key types is sent
    /// with its code.
    var kittyText: Bool
}

extension BarKey {

    /// What pressing this key, with `modifiers` held, sends.
    ///
    /// Without the Kitty protocol, as xterm sends them, matching the
    /// `xterm-256color` terminfo the guest is given: CSI with a modifier
    /// parameter for the cursor and function keys, ESC first for Alt, and F13
    /// to F22 as Shift with F1 to F10, which is how that terminfo names them.
    /// Meta goes into the modifier parameter there, as xterm's Meta bit, but a
    /// character has no legacy form for it and loses it. With the Kitty
    /// protocol, the cursor and function keys are always CSI, as SwiftTerm
    /// sends them from a keyboard, and the keys it gives codes of their own
    /// (Esc, Menu, F13 up, the keypad, and anything modified with no legacy
    /// form) are sent as `CSI code;modifiers u`; when the guest asks for every
    /// key to be reported, so are a plain Tab and the characters.
    ///
    /// Empty for the modifier keys and the arrow pad, which send nothing
    /// themselves.
    func sequence(with modifiers: KeyModifiers, mode: KeyEncodingMode) -> [UInt8] {
        let plain = modifiers.isEmpty

        switch self {
        case .esc:
            if mode.kitty { return Self.csiU(27, modifiers) }
            return modifiers.contains(.alt) ? [0x1b, 0x1b] : [0x1b]

        case .tab:
            if mode.kitty {
                return plain && !mode.kittyAllKeys ? [0x09] : Self.csiU(9, modifiers)
            }
            let prefix: [UInt8] = modifiers.contains(.alt) ? [0x1b] : []
            return prefix + (modifiers.contains(.shift) ? Self.csi("Z") : [0x09])

        case .menu:
            if mode.kitty { return Self.csiU(57363, modifiers) }
            return Self.tilde(29, modifiers)

        case .up: return Self.cursor("A", modifiers, mode)
        case .down: return Self.cursor("B", modifiers, mode)
        case .right: return Self.cursor("C", modifiers, mode)
        case .left: return Self.cursor("D", modifiers, mode)
        case .home: return Self.cursor("H", modifiers, mode)
        case .end: return Self.cursor("F", modifiers, mode)
        case .insert: return Self.tilde(2, modifiers)
        case .forwardDelete: return Self.tilde(3, modifiers)
        case .pageUp: return Self.tilde(5, modifiers)
        case .pageDown: return Self.tilde(6, modifiers)

        case .shift, .ctrl, .alt, .superKey, .arrows, .copy, .paste, .selectAll:
            return []

        default:
            break
        }

        if let number = functionNumber {
            return Self.function(number, modifiers, mode)
        }

        if let digit = keypadDigit {
            if mode.kitty {
                let typesText = modifiers.intersection([.alt, .ctrl, .superKey]).isEmpty
                return Self.csiU(
                    57399 + digit, modifiers, text: mode.kittyText && typesText ? "\(digit)" : nil)
            }
            let prefix: [UInt8] = modifiers.contains(.alt) ? [0x1b] : []
            let base = UInt8(ascii: "0") + UInt8(digit)
            return prefix + (mode.applicationKeypad ? [0x1b, 0x4f, 0x70 + UInt8(digit)] : [base])
        }

        if let character {
            return Self.character(character, modifiers, mode: mode)
        }

        return []
    }

    /// A single character, from the bar or typed with the bar's modifiers.
    ///
    /// With the Kitty protocol, as `CSI code;modifiers u` when Ctrl, Alt or
    /// Meta is on, which the protocol exists to tell apart, or whenever every
    /// key is to be reported. Shift alone just types the shifted character, as
    /// it does on a keyboard. The code is the unshifted key's, Shift being in
    /// the modifiers; the text it types goes in a third field when the guest
    /// asked for it, unless Ctrl, Alt or Meta means it types none. That is how
    /// SwiftTerm encodes keys from the keyboard. Otherwise as `typed`.
    ///
    /// `key`, where it's known, is the key's own character before Shift, for
    /// the Kitty code; `character` is then what the key types, Shift and all,
    /// as a hardware keyboard's layout makes it.
    ///
    /// Return and Tab are keys rather than characters, and are sent as those
    /// keys are: Return as a carriage return, never the newline the keyboard
    /// hands over for it.
    static func character(
        _ character: Character, _ modifiers: KeyModifiers, mode: KeyEncodingMode,
        key: Character? = nil
    ) -> [UInt8] {
        if character == "\t" {
            return BarKey.tab.sequence(with: modifiers, mode: mode)
        }
        if character == "\n" || character == "\r" {
            return returnSequence(modifiers, mode: mode)
        }

        let typesText = modifiers.intersection([.alt, .ctrl, .superKey]).isEmpty

        guard mode.kitty, !typesText || mode.kittyAllKeys,
            let code = String(key ?? character).lowercased().unicodeScalars.first?.value
        else {
            return typed(character, modifiers)
        }

        let text =
            modifiers.contains(.shift) && key == nil
            ? String(character).uppercased() : String(character)
        return csiU(Int(code), modifiers, text: mode.kittyText && typesText ? text : nil)
    }

    /// Return, with modifiers: CR, after ESC for Alt, without the Kitty
    /// protocol; with it, `CSI 13;modifiers u` once there are modifiers or
    /// every key is reported, as SwiftTerm sends it.
    private static func returnSequence(_ modifiers: KeyModifiers, mode: KeyEncodingMode)
        -> [UInt8]
    {
        if mode.kitty {
            return modifiers.isEmpty && !mode.kittyAllKeys ? [0x0d] : csiU(13, modifiers)
        }
        return (modifiers.contains(.alt) ? [0x1b] : []) + [0x0d]
    }

    /// A single typed character with modifiers, without the Kitty protocol:
    /// Shift as the uppercase, Ctrl as its control code where it has one, Alt
    /// as ESC first. Meta has no legacy form, and is dropped.
    static func typed(_ character: Character, _ modifiers: KeyModifiers) -> [UInt8] {
        var text = String(character)
        if modifiers.contains(.shift) {
            text = text.uppercased()
        }

        var bytes = Array(text.utf8)
        if modifiers.contains(.ctrl), bytes.count == 1, let code = controlCode(for: bytes[0]) {
            bytes = [code]
        }
        if modifiers.contains(.alt) {
            bytes = [0x1b] + bytes
        }
        return bytes
    }

    /// The control code Ctrl makes of a typed byte, or nil if it makes none.
    ///
    /// SwiftTerm's own mapping, as its Kitty encoder has it for the legacy
    /// form: the letters, the punctuation around them, and the digits 2 to 8 as
    /// xterm sends them.
    static func controlCode(for byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): byte - 0x40
        case UInt8(ascii: "a")...UInt8(ascii: "z"): byte - 0x60
        case UInt8(ascii: " "), UInt8(ascii: "@"), UInt8(ascii: "2"): 0
        case UInt8(ascii: "["), UInt8(ascii: "3"): 0x1b
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): 0x1c
        case UInt8(ascii: "]"), UInt8(ascii: "5"): 0x1d
        case UInt8(ascii: "^"), UInt8(ascii: "6"): 0x1e
        case UInt8(ascii: "_"), UInt8(ascii: "/"), UInt8(ascii: "7"): 0x1f
        case UInt8(ascii: "?"), UInt8(ascii: "8"): 0x7f
        default: nil
        }
    }

    // MARK: Sequences

    private static func csi(_ body: String) -> [UInt8] {
        [0x1b, 0x5b] + Array(body.utf8)
    }

    /// `CSI code u`, or `CSI code;modifiers u`: the Kitty protocol's form, with
    /// the text the key types as a third field if there is any to send.
    private static func csiU(_ code: Int, _ modifiers: KeyModifiers, text: String? = nil)
        -> [UInt8]
    {
        var body = "\(code)"
        if !modifiers.isEmpty {
            body += ";\(modifiers.parameter)"
        }

        // Control characters are left out of the text, as SwiftTerm leaves them.
        let codepoints = (text ?? "").unicodeScalars
            .filter { !($0.value < 0x20 || (0x7f...0x9f).contains($0.value)) }
            .map { String($0.value) }
        if !codepoints.isEmpty {
            body += (modifiers.isEmpty ? ";;" : ";") + codepoints.joined(separator: ":")
        }

        return csi(body + "u")
    }

    /// `CSI number ~`, or `CSI number;modifiers ~`: Insert, Delete, the page
    /// keys and F5 up.
    private static func tilde(_ number: Int, _ modifiers: KeyModifiers) -> [UInt8] {
        csi(modifiers.isEmpty ? "\(number)~" : "\(number);\(modifiers.parameter)~")
    }

    /// The arrows, Home and End: SS3 or CSI plain, as the cursor mode says, or
    /// `CSI 1;modifiers final` with modifiers. Under the Kitty protocol, always
    /// CSI, whatever the cursor mode.
    private static func cursor(
        _ final: Character, _ modifiers: KeyModifiers, _ mode: KeyEncodingMode
    ) -> [UInt8] {
        if modifiers.isEmpty && mode.kitty {
            return csi(String(final))
        }
        if modifiers.isEmpty {
            return (mode.applicationCursor ? [0x1b, 0x4f] : [0x1b, 0x5b])
                + Array(String(final).utf8)
        }
        return csi("1;\(modifiers.parameter)\(final)")
    }

    /// F1 to F22.
    private static func function(
        _ number: Int, _ modifiers: KeyModifiers, _ mode: KeyEncodingMode
    ) -> [UInt8] {
        if number > 12 {
            if mode.kitty { return csiU(57376 + number - 13, modifiers) }
            return function(number - 12, modifiers.union(.shift), mode)
        }

        // Under the Kitty protocol, F3 is `CSI 13 ~`: as `CSI 1;modifiers R` it would read as a
        // report of where the cursor is. F1, F2 and F4 are CSI there, not SS3.
        if number == 3 && mode.kitty {
            return tilde(13, modifiers)
        }
        if number <= 4 {
            let final = ["P", "Q", "R", "S"][number - 1]
            if modifiers.isEmpty {
                return (mode.kitty ? [0x1b, 0x5b] : [0x1b, 0x4f]) + Array(final.utf8)
            }
            return csi("1;\(modifiers.parameter)\(final)")
        }

        let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
        return tilde(codes[number] ?? 15, modifiers)
    }
}
