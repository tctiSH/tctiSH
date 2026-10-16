//
//  TerminalTheme.swift
//  A terminal theme's colors, and the file a theme is shared as. Shared with
//  the Quick Look extensions, which show theme files in Files.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit
import UniformTypeIdentifiers

/// A color in a theme: sRGB, 8 bits a component, as in `#rrggbb`.
struct ThemeColor: Hashable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    /// From `#rrggbb`, or nil if it isn't written that way.
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces)
        guard digits.hasPrefix("#") else { return nil }
        let value = digits.dropFirst()
        guard value.count == 6, value.allSatisfy(\.isHexDigit),
            let packed = UInt32(value, radix: 16)
        else { return nil }

        red = UInt8(packed >> 16 & 0xff)
        green = UInt8(packed >> 8 & 0xff)
        blue = UInt8(packed & 0xff)
    }

    /// The color in sRGB. A component beyond sRGB's range, which the picker's
    /// Display P3 allows, is clamped to its edge.
    init(_ color: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)

        func byte(_ component: CGFloat) -> UInt8 {
            UInt8((min(max(component, 0), 1) * 255).rounded())
        }
        self.red = byte(red)
        self.green = byte(green)
        self.blue = byte(blue)
    }

    var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }

    var uiColor: UIColor {
        UIColor(
            red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255,
            alpha: 1)
    }
}

/// Saved as `#rrggbb`.
extension ThemeColor: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let color = ThemeColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\(hex) isn't #rrggbb")
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// The colors the terminal draws with, and a name for them.
struct TerminalTheme: Equatable {

    /// The theme's identifier: fixed for a built-in theme ("solarized-dark"), a
    /// UUID for the user's.
    var id: String
    var name: String

    var background: ThemeColor
    var foreground: ThemeColor
    var cursor: ThemeColor

    /// The character under a block cursor.
    var cursorText: ThemeColor

    var selection: ThemeColor
    var selectedText: ThemeColor

    /// The 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan and
    /// white, then the bright version of each.
    var ansi: [ThemeColor]

    /// The name to show, or "Untitled Theme" if it's blank.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Theme" : trimmed
    }

    /// Every color, in `Role.all`'s order, to tell whether two themes look the
    /// same whatever they're called.
    var colors: [ThemeColor] { Role.all.map { self[$0] } }

    /// The style for controls drawn over the terminal: dark on a dark
    /// background, light on a light one.
    var interfaceStyle: UIUserInterfaceStyle {
        Self.interfaceStyle(over: background.uiColor)
    }

    /// The style for controls drawn over `background`.
    static func interfaceStyle(over background: UIColor) -> UIUserInterfaceStyle {
        var white: CGFloat = 0
        background.getWhite(&white, alpha: nil)
        return white < 0.5 ? .dark : .light
    }
}

/// Saved in the defaults as JSON.
extension TerminalTheme: Codable {

    /// A theme saved without a name still reads, as one with a blank name.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        background = try container.decode(ThemeColor.self, forKey: .background)
        foreground = try container.decode(ThemeColor.self, forKey: .foreground)
        cursor = try container.decode(ThemeColor.self, forKey: .cursor)
        cursorText = try container.decode(ThemeColor.self, forKey: .cursorText)
        selection = try container.decode(ThemeColor.self, forKey: .selection)
        selectedText = try container.decode(ThemeColor.self, forKey: .selectedText)
        ansi = try container.decode([ThemeColor].self, forKey: .ansi)
        guard ansi.count == 16 else {
            throw DecodingError.dataCorruptedError(
                forKey: .ansi, in: container, debugDescription: "\(ansi.count) ANSI colors, not 16")
        }
    }
}

// MARK: - The colors a theme sets

extension TerminalTheme {

    /// One of the colors a theme sets.
    enum Role: Hashable {
        case background
        case foreground
        case cursor
        case cursorText
        case selection
        case selectedText

        /// 0 to 7 the colors, 8 to 15 their bright versions.
        case ansi(Int)

        static let text: [Role] = [
            .background, .foreground, .cursor, .cursorText, .selection, .selectedText,
        ]
        static let normal = (0..<8).map(Role.ansi)
        static let bright = (8..<16).map(Role.ansi)
        static let all = text + normal + bright

        private static let hues = [
            "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        ]

        /// As Settings names it.
        var title: String {
            switch self {
            case .background: "Background"
            case .foreground: "Text"
            case .cursor: "Cursor"
            case .cursorText: "Text Under Cursor"
            case .selection: "Selection"
            case .selectedText: "Selected Text"
            case .ansi(let index) where index < 8: Self.hues[index]
            case .ansi(let index): "Bright \(Self.hues[index - 8])"
            }
        }

        /// As a theme file names it.
        var key: String {
            switch self {
            case .background: "background"
            case .foreground: "foreground"
            case .cursor: "cursor"
            case .cursorText: "cursorText"
            case .selection: "selection"
            case .selectedText: "selectedText"
            case .ansi(let index) where index < 8: Self.hues[index].lowercased()
            case .ansi(let index): "bright\(Self.hues[index - 8])"
            }
        }
    }

    subscript(role: Role) -> ThemeColor {
        get {
            switch role {
            case .background: background
            case .foreground: foreground
            case .cursor: cursor
            case .cursorText: cursorText
            case .selection: selection
            case .selectedText: selectedText
            case .ansi(let index): ansi[index]
            }
        }
        set {
            switch role {
            case .background: background = newValue
            case .foreground: foreground = newValue
            case .cursor: cursor = newValue
            case .cursorText: cursorText = newValue
            case .selection: selection = newValue
            case .selectedText: selectedText = newValue
            case .ansi(let index): ansi[index] = newValue
            }
        }
    }
}

// MARK: - Theme files

extension UTType {
    /// A `.tctheme` file: one theme, as JSON that may have comments.
    static let terminalTheme = UTType(exportedAs: "io.ara.tctiSH.terminal-theme")
}

/// Why a file couldn't be read as a theme.
struct ThemeFileError: LocalizedError {
    var errorDescription: String?
}

extension TerminalTheme {

    /// The largest file read as a theme. A theme is about a kilobyte.
    static let largestFile = 64 * 1024

    /// Reads the theme in the file at `url`.
    init(contentsOf url: URL) throws {
        try self.init(file: Self.read(url))
    }

    /// The start of the file at `url`: a byte more than `largestFile` at most,
    /// so that a larger file is told apart without being read whole.
    private static func read(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: largestFile + 1) ?? Data()
    }

    /// The theme as a `.tctheme` file: JSON with comments (JSONC), every color
    /// as `#rrggbb`. The id isn't written; an imported theme gets a new one.
    var fileContents: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let quotedName = (try? encoder.encode(title)).flatMap { String(data: $0, encoding: .utf8) }

        func entries(_ roles: [Role]) -> String {
            roles.map { "  \"\($0.key)\": \"\(self[$0].hex)\"," }.joined(separator: "\n")
        }

        return """
            // A tctiSH terminal theme. Settings > Appearance > Import Theme adds it to tctiSH.
            //
            // Colors are sRGB, written #rrggbb. Comments and trailing commas are allowed.
            {
              "name": \(quotedName ?? "\"Untitled Theme\""),

            \(entries(Role.text))

              // The ANSI colors.
            \(entries(Role.normal))

              // Their bright versions.
            \(entries(Role.bright))
            }

            """
    }

    /// The file name to share the theme as: its title, without the characters
    /// file names can't hold, and short enough for one.
    var fileName: String {
        let allowed = title.unicodeScalars.filter {
            !CharacterSet(charactersIn: "/\\:?*\"<>|").contains($0)
                && !CharacterSet.controlCharacters.contains($0)
        }
        var base = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
        // APFS allows 255 bytes, which the extension and room to spare come out of.
        while base.utf8.count > 200 {
            base.removeLast()
        }
        return "\(base.isEmpty || base.hasPrefix(".") ? "Theme" : base).tctheme"
    }

    /// Reads a theme from a `.tctheme` file, or plain JSON with the same keys.
    /// It has a placeholder id until it's added to the user's themes.
    init(file data: Data) throws {
        guard data.count <= Self.largestFile else {
            throw ThemeFileError(errorDescription: "The file is too large to be a theme.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ThemeFileError(errorDescription: "The file isn't text.")
        }

        let json = Data(Self.removingTrailingCommas(Self.removingComments(text)).utf8)
        guard let object = try? JSONSerialization.jsonObject(with: json),
            let fields = object as? [String: Any]
        else {
            throw ThemeFileError(
                errorDescription:
                    "The file isn't a theme: it should be JSON with the theme's colors.")
        }

        func color(_ role: Role) throws -> ThemeColor {
            guard let value = fields[role.key] else {
                throw ThemeFileError(errorDescription: "The theme has no \"\(role.key)\" color.")
            }
            guard let hex = value as? String, let color = ThemeColor(hex: hex) else {
                throw ThemeFileError(
                    errorDescription:
                        "The theme's \"\(role.key)\" color isn't written #rrggbb.")
            }
            return color
        }

        // Without control characters, such as newlines, which a list row can't show, and no longer
        // than a name anyone would type.
        let named = (fields["name"] as? String)?.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let name = named.map { String(String(String.UnicodeScalarView($0)).prefix(100)) } ?? ""
        self.init(
            id: "", name: name,
            background: try color(.background), foreground: try color(.foreground),
            cursor: try color(.cursor), cursorText: try color(.cursorText),
            selection: try color(.selection), selectedText: try color(.selectedText),
            ansi: try (0..<16).map { try color(.ansi($0)) })
    }

    /// JSONC without its comments: `//` to the end of the line and `/* */`,
    /// outside strings.
    private static func removingComments(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var inString = false
        var pending = scalars.next()

        while let scalar = pending {
            pending = scalars.next()

            if inString {
                result.append(scalar)
                if scalar == "\\", let escaped = pending {
                    result.append(escaped)
                    pending = scalars.next()
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }

            if scalar == "/", pending == "/" {
                while let next = pending, next != "\n" {
                    pending = scalars.next()
                }
                continue
            }
            if scalar == "/", pending == "*" {
                pending = scalars.next()
                var previous: Unicode.Scalar?
                while let next = pending {
                    pending = scalars.next()
                    if previous == "*", next == "/" { break }
                    previous = next
                }
                // A space where the comment was, so it still separates what was either side.
                result.append(" ")
                continue
            }

            if scalar == "\"" {
                inString = true
            }
            result.append(scalar)
        }
        return String(result)
    }

    /// JSON without the commas JSONC allows before a closing brace or bracket,
    /// outside strings. Comments must already be gone.
    private static func removingTrailingCommas(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var inString = false
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            index += 1

            if inString {
                result.append(scalar)
                if scalar == "\\", index < scalars.count {
                    result.append(scalars[index])
                    index += 1
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }

            if scalar == "," {
                let next = scalars[index...].first {
                    !CharacterSet.whitespacesAndNewlines.contains($0)
                }
                if next == "}" || next == "]" { continue }
            }
            if scalar == "\"" {
                inString = true
            }
            result.append(scalar)
        }
        return String(result)
    }
}
