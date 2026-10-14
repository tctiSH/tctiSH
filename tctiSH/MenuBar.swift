//
//  MenuBar.swift
//  The menu bar's commands on iPad, and the same shortcuts on iPhone.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// tctiSH's commands in the menu bar, where Safari and Terminal on the Mac put
/// theirs, with their shortcuts.
///
/// The actions belong to `ViewController`, which is reached through the
/// responder chain from whatever has focus. iPhone has no menu bar, so there
/// the commands with shortcuts are that view controller's key commands instead.
///
/// Each ⌘ shortcut here is a key combination that Linux doesn't get as Super.
/// With Send ⌘ Shortcuts to Linux on, only the shortcuts for Settings and the
/// TTYs stay; the other commands stay in the menus, without a shortcut.
enum MenuBar {

    /// The Machine menu, between View and Window.
    static let machine = UIMenu.Identifier("io.ara.tctish.menu.machine")

    /// Whether ⌘ shortcuts go to Linux, except those that tctiSH keeps.
    static var sendsShortcutsToLinux: Bool { AppSetting.sendShortcutsToLinux.bool }

    /// The commands that keep their shortcuts even when ⌘ shortcuts go to
    /// Linux: Settings, which on iPhone can otherwise be out of reach of a
    /// keyboard, and those that open, close and move between TTYs, and open and
    /// close windows.
    private static let kept: Set<Selector> = [
        #selector(ViewController.openSettings(_:)),
        #selector(ViewController.openNewWindow(_:)),
        #selector(ViewController.newTTY(_:)),
        #selector(ViewController.closeTTY(_:)),
        #selector(ViewController.closeWindow(_:)),
        #selector(ViewController.toggleSwitcher(_:)),
        #selector(ViewController.previousTTY(_:)),
        #selector(ViewController.nextTTY(_:)),
        #selector(ViewController.jumpToTTY(_:)),
    ]

    private static func keepsShortcut(for action: Selector) -> Bool {
        !sendsShortcutsToLinux || kept.contains(action)
    }

    // MARK: Building

    /// The number of windows when the menu bar was last built, for
    /// `watchWindows`.
    private static var builtWindowCount = 0

    /// Fills in the main menu bar. Called from `AppDelegate.buildMenu(with:)`,
    /// and again whenever the menu system is told to rebuild, as when Send ⌘
    /// Shortcuts to Linux changes, or a window opens or closes.
    static func build(with builder: UIMenuBuilder) {
        builtWindowCount = TTYs.shared.windows.count

        // Where the system keeps its Settings item, if it offers one there; otherwise at the top of
        // the app menu, which is where that item goes on the Mac.
        if builder.menu(for: .preferences) != nil {
            builder.replaceChildren(ofMenu: .preferences) { _ in settingsCommands }
        } else {
            builder.insertChild(
                UIMenu(options: .displayInline, children: settingsCommands),
                atStartOfMenu: .application)
        }

        buildEdit(with: builder)

        // The terminal is all there is to show.
        if builder.menu(for: .sidebar) != nil {
            builder.remove(menu: .sidebar)
        }

        // The key bar is tctiSH's toolbar.
        if builder.menu(for: .toolbar) != nil {
            builder.replaceChildren(ofMenu: .toolbar) { _ in keyBarCommands }
        } else {
            builder.insertChild(
                UIMenu(options: .displayInline, children: keyBarCommands),
                atStartOfMenu: .view)
        }

        // Close Window takes Safari's ⌘⇧W, since ⌘W closes a TTY, and is followed by the other
        // choice of what happens to the programs in it. They replace the system's Close Window, in
        // File, or without one, go at the top of Window.
        if builder.menu(for: .close) != nil {
            builder.replaceChildren(ofMenu: .close) { _ in closeWindowCommands }
        } else {
            builder.insertChild(
                UIMenu(options: .displayInline, children: closeWindowCommands),
                atStartOfMenu: .window)
        }

        // New Window is tctiSH's, in File, as iPadOS doesn't give the system's one a shortcut.
        if builder.menu(for: .newScene) != nil {
            builder.remove(menu: .newScene)
        }
        insert(fileGroups, atStartOf: .file, in: builder)
        insert(viewGroups, atStartOf: .view, in: builder)
        insert(windowGroups, atStartOf: .window, in: builder)

        builder.insertSibling(
            UIMenu(title: "Machine", identifier: machine, children: machineElements),
            afterMenu: .view)
    }

    /// Edit, cut down to what a terminal can do: its text belongs to Linux, so
    /// there's nothing to undo, cut, delete or restyle. Copy, Paste and Select
    /// All stay, Clear Scrollback joins them, and Find keeps all but Find and
    /// Replace.
    private static func buildEdit(with builder: UIMenuBuilder) {
        let unwanted: [UIMenu.Identifier] = [
            .undoRedo, .spelling, .substitutions, .transformations, .speech, .format,
        ]
        for menu in unwanted where builder.menu(for: menu) != nil {
            builder.remove(menu: menu)
        }

        let unwantedActions: Set<Selector> = [
            #selector(UIResponderStandardEditActions.cut(_:)),
            #selector(UIResponderStandardEditActions.delete(_:)),
            #selector(UIResponderStandardEditActions.pasteAndMatchStyle(_:)),
            #selector(UIResponder.findAndReplace(_:)),
        ]
        // Find is the system's, Use Selection for Find included; it's added in case it ever isn't.
        let useSelection = #selector(UIResponder.useSelectionForFind(_:))
        for menu: UIMenu.Identifier in [.standardEdit, .find] where builder.menu(for: menu) != nil {
            builder.replaceChildren(ofMenu: menu) { children in
                var children = children.filter { element in
                    guard let action = (element as? UICommand)?.action else { return true }
                    return !unwantedActions.contains(action)
                }
                if menu == .find,
                    !children.contains(where: { ($0 as? UICommand)?.action == useSelection })
                {
                    children.append(command("Use Selection for Find", useSelection, "e"))
                }
                return children.map(withoutShortcutIfSent)
            }
        }

        let clear = UIMenu(options: .displayInline, children: editCommands)
        if builder.menu(for: .standardEdit) != nil {
            builder.insertSibling(clear, afterMenu: .standardEdit)
        } else {
            builder.insertChild(clear, atEndOfMenu: .edit)
        }
    }

    /// Puts `groups` at the start of `menu`, in order, each set apart from the
    /// next. Where the system has no such menu, at the end of View instead.
    private static func insert(
        _ groups: [[UIMenuElement]], atStartOf menu: UIMenu.Identifier, in builder: UIMenuBuilder
    ) {
        let groups = groups.map { UIMenu(options: .displayInline, children: $0) }
        guard builder.menu(for: menu) != nil else {
            groups.forEach { builder.insertChild($0, atEndOfMenu: .view) }
            return
        }
        // Each goes in at the start, so the last goes first.
        groups.reversed().forEach { builder.insertChild($0, atStartOfMenu: menu) }
    }

    /// Has the menu bar rebuilt as a window opens or closes: Move Terminal to
    /// lists one item for each other window. Called once, at launch.
    static func watchWindows() {
        guard WindowScenes.areAvailable else { return }
        NotificationCenter.default.addObserver(
            forName: TTYs.didChange, object: nil, queue: .main
        ) { _ in
            guard TTYs.shared.windows.count != builtWindowCount else { return }
            UIMenuSystem.main.setNeedsRebuild()
        }
    }

    /// A system command as it is, or without its shortcut if that goes to
    /// Linux.
    private static func withoutShortcutIfSent(_ element: UIMenuElement) -> UIMenuElement {
        guard let key = element as? UIKeyCommand, let action = key.action,
            !keepsShortcut(for: action)
        else { return element }
        return withoutShortcut(element)
    }

    /// A menu element without the shortcuts in it, those in its submenus
    /// included.
    private static func withoutShortcut(_ element: UIMenuElement) -> UIMenuElement {
        if let menu = element as? UIMenu {
            return menu.replacingChildren(menu.children.map(withoutShortcut))
        }
        guard let key = element as? UIKeyCommand, let action = key.action else { return element }

        return UICommand(
            title: key.title, image: key.image, action: action, propertyList: key.propertyList,
            alternates: key.alternates, discoverabilityTitle: key.discoverabilityTitle,
            attributes: key.attributes, state: key.state)
    }

    // MARK: The commands

    // Each list is made anew on every call, because a command can be in only one place.

    /// A command, with its shortcut unless that goes to Linux.
    private static func command(
        _ title: String, _ action: Selector, _ input: String? = nil,
        _ modifiers: UIKeyModifierFlags = .command, propertyList: Any? = nil
    ) -> UICommand {
        guard let input, keepsShortcut(for: action) else {
            return UICommand(title: title, action: action, propertyList: propertyList)
        }
        return UIKeyCommand(
            title: title, action: action, input: input, modifierFlags: modifiers,
            propertyList: propertyList)
    }

    private static var settingsCommands: [UICommand] {
        [command("Settings…", #selector(ViewController.openSettings(_:)), ",")]
    }

    private static var keyBarCommands: [UICommand] {
        [
            command(
                "Show Key Bar With Hardware Keyboard",
                #selector(ViewController.toggleKeyBarWithHardwareKeyboard(_:))),
            command("Customize Toolbar…", #selector(ViewController.customizeKeyBar(_:))),
        ]
    }

    /// Close Window, and the item under it, named for what it does to the
    /// programs. Settings has the menu rebuilt when that changes.
    private static var closeWindowCommands: [UICommand] {
        [
            command(
                "Close Window", #selector(ViewController.closeWindow(_:)), "w", [.command, .shift]),
            command(
                AppSetting.keepProgramsWhenClosingWindow.bool
                    ? "Close Window and End Programs" : "Close Window and Keep Programs Running",
                #selector(ViewController.closeWindowOtherwise(_:))),
        ]
    }

    /// File: on iPad, New Window; then opening and closing TTYs, stealing
    /// Safari's shortcuts for tabs; then the selected TTY's name, pin and bell,
    /// as its menu in the switcher has them; then, on iPad, moving it to
    /// another window; then saving its text.
    private static var fileGroups: [[UIMenuElement]] {
        var groups: [[UIMenuElement]] = [
            [
                command("New Terminal", #selector(ViewController.newTTY(_:)), "t"),
                command("Close Terminal", #selector(ViewController.closeTTY(_:)), "w"),
                command(
                    "Close Other Terminals", #selector(ViewController.closeOtherTTYs(_:)), "w",
                    [.command, .alternate]),
            ],
            [
                command("Rename Terminal…", #selector(ViewController.renameTTY(_:))),
                command("Pin Terminal", #selector(ViewController.togglePinned(_:))),
                command("Mute Terminal", #selector(ViewController.toggleMuted(_:))),
            ],
            [command("Export Text As…", #selector(ViewController.exportText(_:)), "s")],
        ]
        if WindowScenes.areAvailable {
            groups[0].insert(
                command("New Window", #selector(ViewController.openNewWindow(_:)), "n"), at: 0)
            groups.insert(moveCommands, at: 2)
        }
        return groups
    }

    /// Move Terminal to New Window, and while there are other windows, Move
    /// Terminal to, with one item for each, which the view controller names for
    /// its window as the menu opens.
    private static var moveCommands: [UIMenuElement] {
        var commands: [UIMenuElement] = [
            command(
                "Move Terminal to New Window", #selector(ViewController.moveTTYToNewWindow(_:)))
        ]
        let others = TTYs.shared.windows.count - 1
        if others > 0 {
            commands.append(
                UIMenu(
                    title: "Move Terminal to",
                    children: (0..<others).map { index in
                        command(
                            "Window \(index + 1)", #selector(ViewController.moveTTYToWindow(_:)),
                            propertyList: index)
                    }))
        }
        return commands
    }

    /// Edit > Find's commands, which the system makes for the menu bar on iPad.
    private static var findCommands: [UICommand] {
        [
            command("Find…", #selector(UIResponder.find(_:)), "f"),
            command("Use Selection for Find", #selector(UIResponder.useSelectionForFind(_:)), "e"),
        ]
    }

    /// Edit: clearing the scrollback, which only tctiSH holds.
    private static var editCommands: [UICommand] {
        [command("Clear Scrollback", #selector(ViewController.clearScrollback(_:)), "k")]
    }

    /// View: the switcher; the selected TTY's font size, with Terminal's
    /// shortcuts; and scrolling to either end.
    private static var viewGroups: [[UIMenuElement]] {
        [
            [
                command(
                    "Show All Terminals", #selector(ViewController.toggleSwitcher(_:)), "\\",
                    [.command, .shift])
            ],
            [
                command("Bigger", #selector(ViewController.makeTextBigger(_:)), "+"),
                command("Smaller", #selector(ViewController.makeTextSmaller(_:)), "-"),
                command("Default Font Size", #selector(ViewController.useDefaultFontSize(_:)), "0"),
            ],
            [
                command(
                    "Scroll to Top", #selector(ViewController.scrollToTop(_:)),
                    UIKeyCommand.inputHome),
                command(
                    "Scroll to Bottom", #selector(ViewController.scrollToBottom(_:)),
                    UIKeyCommand.inputEnd),
            ],
        ]
    }

    /// Window: the previous and next TTYs, ⌘1 to ⌘8 by position in the step
    /// order, ⌘9 for the last; then the system TTYs; then, on iPad, Merge All
    /// Windows. The view controller names the numbered commands for their TTYs
    /// as the menu opens.
    private static var windowGroups: [[UIMenuElement]] {
        [stepCommands + numberedCommands, systemTTYCommands] + mergeCommands
    }

    private static var mergeCommands: [[UIMenuElement]] {
        guard WindowScenes.areAvailable else { return [] }
        return [[command("Merge All Windows", #selector(ViewController.mergeAllWindows(_:)))]]
    }

    private static var stepCommands: [UICommand] {
        [
            command(
                "Show Previous Terminal", #selector(ViewController.previousTTY(_:)), "[",
                [.command, .shift]),
            command(
                "Show Next Terminal", #selector(ViewController.nextTTY(_:)), "]",
                [.command, .shift]),
        ]
    }

    private static var numberedCommands: [UICommand] {
        (1...9).map { number in
            command(
                number == 9 ? "Show Last Terminal" : "Show Terminal \(number)",
                #selector(ViewController.jumpToTTY(_:)), "\(number)", propertyList: number)
        }
    }

    /// Kernel Log and VM Management, each listed only while the switcher shows
    /// it and it is not among the numbered commands.
    private static var systemTTYCommands: [UICommand] {
        [
            command("Kernel Log", #selector(ViewController.showKernelLog(_:))),
            command("VM Management", #selector(ViewController.showVMManagement(_:))),
        ]
    }

    /// Machine: the settings worth changing in a hurry, all of which apply
    /// straight away; then what starts Linux again or rewrites its disk, each
    /// of which asks first. No shortcuts, as none of these should be a slip of
    /// the fingers away.
    private static var machineElements: [UIMenuElement] {
        let modes = ExecutionMode.allCases.map { mode in
            command(
                mode.title, #selector(ViewController.setExecutionMode(_:)),
                propertyList: mode.rawValue)
        }
        let vcpus = (1...max(Vcpus.maximum, 1)).map { count in
            command(
                count == 1 ? "1 vCPU" : "\(count) vCPUs", #selector(ViewController.setVcpus(_:)),
                propertyList: count)
        }

        return [
            UIMenu(
                options: .displayInline,
                children: [
                    command("Switch to JIT…", #selector(ViewController.switchBackend(_:))),
                    UIMenu(
                        title: "Execution Mode", image: UIImage(systemName: "bolt"),
                        children: modes),
                    UIMenu(title: "vCPUs", image: UIImage(systemName: "cpu"), children: vcpus),
                    command(
                        "Keep Screen Awake", #selector(ViewController.toggleKeepScreenAwake(_:))),
                ]),
            UIMenu(
                options: .displayInline,
                children: [
                    command("Recovery Boot…", #selector(ViewController.confirmRecoveryBoot(_:))),
                    command("Compact Disk…", #selector(ViewController.compactDisk(_:))),
                ]),
        ]
    }

    // MARK: Without a menu bar

    /// Whether there's a menu bar: on iPad from iPadOS 26, where it's always a
    /// pull from the top away. Before that, iPad shows the commands only as a
    /// list of shortcuts, while ⌘ is held on a hardware keyboard.
    static var exists: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return UIDevice.current.userInterfaceIdiom == .pad
    }

    /// The menus, for the key bar's More where there's no menu bar to hold
    /// them.
    ///
    /// Without shortcuts, which a touch menu has no use for, and without what
    /// is only quicker from a keyboard: ⌘1 to ⌘9; Find Next and Previous, which
    /// the find bar has buttons for; and Copy, Paste and Select All, which the
    /// key bar has already.
    static var touchMenus: [UIMenuElement] {
        func menu(_ title: String, _ symbol: String, _ groups: [[UIMenuElement]]) -> UIMenu {
            let children = groups.map { group in
                withoutShortcut(UIMenu(options: .displayInline, children: group))
            }
            return UIMenu(title: title, image: UIImage(systemName: symbol), children: children)
        }

        return [
            menu("File", "doc", fileGroups + closeCommandsForTouch),
            menu("Edit", "pencil", [findCommands, editCommands]),
            menu("View", "eye", viewGroups + [keyBarCommands]),
            menu("Window", "macwindow", [stepCommands, systemTTYCommands] + mergeCommands),
            menu("Machine", "cpu", [machineElements]),
        ]
    }

    /// Close Window and the item under it, for the touch File menu on iPad. In
    /// the menu bar, they replace the system's Close Window.
    private static var closeCommandsForTouch: [[UIMenuElement]] {
        WindowScenes.areAvailable ? [closeWindowCommands] : []
    }

    /// Every command with a shortcut, as key commands, for iPhone. Find comes
    /// from the system on iPad, so is made here.
    static var phoneKeyCommands: [UIKeyCommand] {
        let elements: [UIMenuElement] =
            settingsCommands + fileGroups.joined() + editCommands + findCommands
            + viewGroups.joined() + windowGroups.joined()
        return elements.compactMap { $0 as? UIKeyCommand } + alternateKeyCommands
    }

    /// The shortcuts a menu item can show only one of: ⌘= for Bigger, as well
    /// as ⌘+, since + is a shifted key on most keyboards. Answered on iPad too.
    static var alternateKeyCommands: [UIKeyCommand] {
        let bigger = #selector(ViewController.makeTextBigger(_:))
        guard keepsShortcut(for: bigger) else { return [] }
        return [
            UIKeyCommand(title: "Bigger", action: bigger, input: "=", modifierFlags: .command)
        ]
    }
}
