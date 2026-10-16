//
//  TerminalThemes.swift
//  The terminal's themes: the built-in ones and the user's, and which of them
//  each appearance uses.
//
//  Copyright © 2026 Ara Adkins.
//

import SwiftTerm
import UIKit

extension ThemeColor {
    /// As SwiftTerm has it, in 16 bits a component.
    var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }
}

// MARK: - Which themes there are, and which is in use

/// The themes on offer by default, and which of them the terminals use in dark
/// mode and in light mode.
///
/// The user's themes are kept in the defaults as JSON. Use from the main
/// thread.
enum TerminalThemes {

    /// Posted on the main queue when a theme is chosen for an appearance, one
    /// of the user's themes is saved or deleted, or iOS changes appearance.
    /// Once per turn of the run loop at most, since a color well being dragged
    /// saves on every move.
    static let didChange = Notification.Name("io.ara.tctish.terminalThemesDidChange")

    /// Which of iOS's appearances a theme is chosen for.
    enum Appearance: CaseIterable {
        case dark
        case light

        /// Dark unless iOS says light, so that an unspecified style counts as
        /// dark.
        init(_ style: UIUserInterfaceStyle) {
            self = style == .light ? .light : .dark
        }

        /// The appearance iOS is in where `view` is shown. Read from the window
        /// scene, since a parent can force the view dark (the switcher does). A
        /// view in no window, such as a terminal not on screen, reads the
        /// active scene.
        init(of view: UIView) {
            let scene = view.window?.windowScene ?? Self.activeScene
            self.init(
                scene?.traitCollection.userInterfaceStyle ?? view.traitCollection.userInterfaceStyle
            )
        }

        private static var activeScene: UIWindowScene? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        }

        /// "Dark Mode" or "Light Mode", as Settings words it.
        var title: String {
            switch self {
            case .dark: "Dark Mode"
            case .light: "Light Mode"
            }
        }

        /// The title of its theme setting, "Dark Theme" or "Light Theme", in
        /// Settings and the menu bar.
        var themeTitle: String {
            switch self {
            case .dark: "Dark Theme"
            case .light: "Light Theme"
            }
        }

        /// Its symbol, beside its theme setting and its Use switch.
        var symbol: String {
            switch self {
            case .dark: "moon"
            case .light: "sun.max"
            }
        }

        /// The built-in theme it uses until another is chosen.
        var defaultID: String {
            switch self {
            case .dark: "solarized-dark"
            case .light: "solarized-light"
            }
        }

        fileprivate var setting: AppSetting {
            switch self {
            case .dark: .darkTerminalTheme
            case .light: .lightTerminalTheme
            }
        }
    }

    /// The user's themes, oldest first.
    static var custom: [TerminalTheme] { saved.themes }

    /// The user's themes as saved, read once and then kept up to date by
    /// `store`, since every terminal asks on every change.
    ///
    /// `unreadable` holds the entries that didn't read as themes, such as one
    /// with a color that isn't #rrggbb or a field missing. They're written back
    /// as they were, so that a save here doesn't lose them.
    private static var saved: (themes: [TerminalTheme], unreadable: [Any]) {
        if let cached { return cached }
        let read = readSaved()
        cached = read
        return read
    }

    private static var cached: (themes: [TerminalTheme], unreadable: [Any])?

    private static func readSaved() -> (themes: [TerminalTheme], unreadable: [Any]) {
        guard let data = AppSetting.customTerminalThemes.data else { return ([], []) }
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            // Kept aside, as nothing in it can be written back.
            Log.ui.warn("themes: the custom themes aren't a list; moved to \(Self.unreadableKey)")
            UserDefaults.standard.set(data, forKey: Self.unreadableKey)
            AppSetting.customTerminalThemes.clear()
            return ([], [])
        }

        var themes: [TerminalTheme] = []
        var unreadable: [Any] = []
        for entry in entries {
            do {
                // Checked first, as JSONSerialization raises an exception for anything else.
                guard JSONSerialization.isValidJSONObject(entry) else {
                    throw ThemeFileError(errorDescription: "not a JSON object")
                }
                let json = try JSONSerialization.data(withJSONObject: entry)
                themes.append(try JSONDecoder().decode(TerminalTheme.self, from: json))
            } catch {
                Log.ui.warn("themes: kept a custom theme that couldn't be read: \(error)")
                unreadable.append(entry)
            }
        }
        return (themes, unreadable)
    }

    /// Where custom themes that aren't a list at all are kept.
    private static let unreadableKey = "unreadable_custom_terminal_themes"

    static var all: [TerminalTheme] { builtIn + custom }

    static func theme(withID id: String) -> TerminalTheme? {
        all.first { $0.id == id }
    }

    /// The theme in use for `appearance`: the one chosen, or the default if
    /// that has been deleted.
    static func selected(for appearance: Appearance) -> TerminalTheme {
        theme(withID: appearance.setting.string)
            ?? builtIn.first { $0.id == appearance.defaultID }
            ?? builtIn[0]
    }

    /// The appearances that `id` is in use for.
    static func appearances(using id: String) -> [Appearance] {
        Appearance.allCases.filter { selected(for: $0).id == id }
    }

    /// Uses the theme `id` for `appearance`, or nil for the default.
    static func select(_ id: String?, for appearance: Appearance) {
        appearance.setting.set(id ?? appearance.defaultID)
        changed()
    }

    /// Replaces the user's theme with `theme`'s id, and returns false if there
    /// is none, as when it was deleted in another window.
    @discardableResult
    static func update(_ theme: TerminalTheme) -> Bool {
        var themes = custom
        guard let index = themes.firstIndex(where: { $0.id == theme.id }) else { return false }
        themes[index] = theme
        store(themes)
        return true
    }

    /// Deletes one of the user's themes. An appearance that used it goes back
    /// to its default.
    static func delete(_ id: String) {
        for appearance in appearances(using: id) {
            appearance.setting.clear()
        }
        store(custom.filter { $0.id != id })
    }

    /// Adds a copy of `theme` to the user's themes, as "<name> Copy", and
    /// returns it.
    static func copy(_ theme: TerminalTheme) -> TerminalTheme {
        add(theme, named: "\(theme.title) Copy")
    }

    /// Adds the theme in the file at `url` to the user's themes, and returns
    /// it.
    static func importFile(at url: URL) throws -> TerminalTheme {
        let file = try TerminalTheme(contentsOf: url)
        let theme = add(file, named: file.title)
        Log.ui.note("themes: imported \(theme.title) from \(url.lastPathComponent)")
        return theme
    }

    /// Adds `theme` to the user's themes, under a new id, as `name`, or if a
    /// theme already has that, `name` with a number after it.
    private static func add(_ theme: TerminalTheme, named name: String) -> TerminalTheme {
        var added = theme
        added.id = UUID().uuidString
        added.name = uniqueName(for: name)
        store(custom + [added])
        return added
    }

    /// `name`, or if a theme already has it, `name` with the first number from
    /// 2 that no theme has after it.
    private static func uniqueName(for name: String) -> String {
        let taken = Set(all.map(\.title))
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)") {
            number += 1
        }
        return "\(name) \(number)"
    }

    private static func store(_ themes: [TerminalTheme]) {
        let unreadable = saved.unreadable
        cached = (themes, unreadable)
        do {
            let entries = try themes.map {
                try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
            }
            AppSetting.customTerminalThemes.set(
                try JSONSerialization.data(withJSONObject: entries + unreadable))
        } catch {
            Log.ui.warn("themes: couldn't save the custom themes: \(error)")
        }
        changed()
    }

    /// Says iOS's appearance may have changed. Terminals not on screen get no
    /// trait change for it, so they hear of it this way.
    static func appearanceChanged() {
        changed()
    }

    private static var changePosted = false

    private static func changed() {
        guard !changePosted else { return }
        changePosted = true
        DispatchQueue.main.async {
            changePosted = false
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

// MARK: - The built-in themes

extension TerminalThemes {

    /// The themes tctiSH comes with, in the order Settings lists them.
    static let builtIn: [TerminalTheme] = [
        theme(
            "solarized-dark", "Solarized Dark",
            background: "#002b36", foreground: "#839496", cursor: "#839496",
            cursorText: "#073642", selection: "#073642", selectedText: "#93a1a1",
            ansi: solarized),
        theme(
            "solarized-light", "Solarized Light",
            background: "#fdf6e3", foreground: "#657b83", cursor: "#657b83",
            cursorText: "#eee8d5", selection: "#eee8d5", selectedText: "#586e75",
            ansi: solarized),
        // Base16's Monokai, as most terminal ports have it. Its yellow, #f4bf75, is more orange
        // than the editor theme's #e6db74.
        theme(
            "monokai", "Monokai",
            background: "#272822", foreground: "#f8f8f2", cursor: "#f8f8f0",
            cursorText: "#272822", selection: "#49483e", selectedText: "#f8f8f2",
            ansi: [
                "#272822", "#f92672", "#a6e22e", "#f4bf75",
                "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
                "#75715e", "#f92672", "#a6e22e", "#f4bf75",
                "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5",
            ]),
        theme(
            "dracula", "Dracula",
            background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2",
            cursorText: "#282a36", selection: "#44475a", selectedText: "#f8f8f2",
            ansi: [
                "#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
                "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
                "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
            ]),
        theme(
            "nord", "Nord",
            background: "#2e3440", foreground: "#d8dee9", cursor: "#d8dee9",
            cursorText: "#2e3440", selection: "#434c5e", selectedText: "#d8dee9",
            ansi: [
                "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
            ]),
        theme(
            "gruvbox-dark", "Gruvbox Dark",
            background: "#282828", foreground: "#ebdbb2", cursor: "#ebdbb2",
            cursorText: "#282828", selection: "#504945", selectedText: "#ebdbb2",
            ansi: [
                "#282828", "#cc241d", "#98971a", "#d79921",
                "#458588", "#b16286", "#689d6a", "#a89984",
                "#928374", "#fb4934", "#b8bb26", "#fabd2f",
                "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
            ]),
        theme(
            "gruvbox-light", "Gruvbox Light",
            background: "#fbf1c7", foreground: "#3c3836", cursor: "#3c3836",
            cursorText: "#fbf1c7", selection: "#d5c4a1", selectedText: "#3c3836",
            ansi: [
                "#fbf1c7", "#cc241d", "#98971a", "#d79921",
                "#458588", "#b16286", "#689d6a", "#7c6f64",
                "#928374", "#9d0006", "#79740e", "#b57614",
                "#076678", "#8f3f71", "#427b58", "#3c3836",
            ]),
        theme(
            "one-dark", "One Dark",
            background: "#282c34", foreground: "#abb2bf", cursor: "#528bff",
            cursorText: "#282c34", selection: "#3e4451", selectedText: "#abb2bf",
            ansi: [
                "#282c34", "#e06c75", "#98c379", "#e5c07b",
                "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                "#5c6370", "#e06c75", "#98c379", "#e5c07b",
                "#61afef", "#c678dd", "#56b6c2", "#ffffff",
            ]),
        theme(
            "one-light", "One Light",
            background: "#fafafa", foreground: "#383a42", cursor: "#526fff",
            cursorText: "#fafafa", selection: "#e5e5e6", selectedText: "#383a42",
            ansi: [
                "#383a42", "#e45649", "#50a14f", "#c18401",
                "#4078f2", "#a626a4", "#0184bc", "#a0a1a7",
                "#696c77", "#ca1243", "#50a14f", "#986801",
                "#4078f2", "#a626a4", "#0184bc", "#fafafa",
            ]),
        theme(
            "tokyo-night", "Tokyo Night",
            background: "#1a1b26", foreground: "#c0caf5", cursor: "#c0caf5",
            cursorText: "#1a1b26", selection: "#283457", selectedText: "#c0caf5",
            ansi: [
                "#15161e", "#f7768e", "#9ece6a", "#e0af68",
                "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                "#414868", "#ff899d", "#9fe044", "#faba4a",
                "#8db0ff", "#c7a9ff", "#a4daff", "#c0caf5",
            ]),
        theme(
            "catppuccin-mocha", "Catppuccin Mocha",
            background: "#1e1e2e", foreground: "#cdd6f4", cursor: "#f5e0dc",
            cursorText: "#1e1e2e", selection: "#585b70", selectedText: "#cdd6f4",
            ansi: [
                "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af",
                "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
                "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
            ]),
        theme(
            "catppuccin-latte", "Catppuccin Latte",
            background: "#eff1f5", foreground: "#4c4f69", cursor: "#dc8a78",
            cursorText: "#eff1f5", selection: "#acb0be", selectedText: "#4c4f69",
            ansi: [
                "#5c5f77", "#d20f39", "#40a02b", "#df8e1d",
                "#1e66f5", "#ea76cb", "#179299", "#acb0be",
                "#6c6f85", "#d20f39", "#40a02b", "#df8e1d",
                "#1e66f5", "#ea76cb", "#179299", "#bcc0cc",
            ]),
        theme(
            "tomorrow-night", "Tomorrow Night",
            background: "#1d1f21", foreground: "#c5c8c6", cursor: "#c5c8c6",
            cursorText: "#1d1f21", selection: "#373b41", selectedText: "#c5c8c6",
            ansi: [
                "#1d1f21", "#cc6666", "#b5bd68", "#f0c674",
                "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
                "#969896", "#cc6666", "#b5bd68", "#f0c674",
                "#81a2be", "#b294bb", "#8abeb7", "#ffffff",
            ]),
        theme(
            "github-dark", "GitHub Dark",
            background: "#0d1117", foreground: "#e6edf3", cursor: "#2f81f7",
            cursorText: "#0d1117", selection: "#264f78", selectedText: "#e6edf3",
            ansi: [
                "#484f58", "#ff7b72", "#3fb950", "#d29922",
                "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
                "#6e7681", "#ffa198", "#56d364", "#e3b341",
                "#79c0ff", "#d2a8ff", "#56d4dd", "#ffffff",
            ]),
        theme(
            "github-light", "GitHub Light",
            background: "#ffffff", foreground: "#1f2328", cursor: "#0969da",
            cursorText: "#ffffff", selection: "#b6e3ff", selectedText: "#1f2328",
            ansi: [
                "#24292f", "#cf222e", "#116329", "#4d2d00",
                "#0969da", "#8250df", "#1b7c83", "#6e7781",
                "#57606a", "#a40e26", "#1a7f37", "#633c01",
                "#218bff", "#a475f9", "#3192aa", "#8c959f",
            ]),
        theme(
            "tango-dark", "Tango Dark",
            background: "#2e3436", foreground: "#d3d7cf", cursor: "#d3d7cf",
            cursorText: "#2e3436", selection: "#555753", selectedText: "#eeeeec",
            ansi: tango),
        theme(
            "tango-light", "Tango Light",
            background: "#eeeeec", foreground: "#2e3436", cursor: "#2e3436",
            cursorText: "#eeeeec", selection: "#d3d7cf", selectedText: "#2e3436",
            ansi: tango),
    ]

    /// Solarized's colors, which its dark and light themes share.
    private static let solarized = [
        "#073642", "#dc322f", "#859900", "#b58900",
        "#268bd2", "#d33682", "#2aa198", "#eee8d5",
        "#002b36", "#cb4b16", "#586e75", "#657b83",
        "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
    ]

    /// The Tango palette, as GNOME Terminal has it.
    private static let tango = [
        "#2e3436", "#cc0000", "#4e9a06", "#c4a000",
        "#3465a4", "#75507b", "#06989a", "#d3d7cf",
        "#555753", "#ef2929", "#8ae234", "#fce94f",
        "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
    ]

    /// A built-in theme. Its colors are literals, so a bad one is a programmer
    /// error.
    private static func theme(
        _ id: String, _ name: String, background: String, foreground: String, cursor: String,
        cursorText: String, selection: String, selectedText: String, ansi: [String]
    ) -> TerminalTheme {
        func color(_ hex: String) -> ThemeColor { ThemeColor(hex: hex)! }

        precondition(ansi.count == 16, "\(name) needs 16 ANSI colors")
        return TerminalTheme(
            id: id, name: name,
            background: color(background), foreground: color(foreground), cursor: color(cursor),
            cursorText: color(cursorText), selection: color(selection),
            selectedText: color(selectedText), ansi: ansi.map(color))
    }
}
