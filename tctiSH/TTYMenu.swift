//
//  TTYMenu.swift
//  The menu of actions for a TTY, shown from the TTY's card or pill in the
//  switcher, and from the switcher button for the selected TTY.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// Builds a TTY's menu containing its actions: renaming, changing scrollback
/// length, and so on.
final class TTYMenu {

    private let store = TTYs.shared

    /// The view controller that presents the alerts.
    private weak var presenter: UIViewController?

    /// Runs the Search item for a TTY.
    private let search: (TTY) -> Void

    /// The context menu interaction showing the menu. It is kept so that the
    /// menu can be rebuilt while it stays open, as the font size is stepped.
    private weak var interaction: UIContextMenuInteraction?

    init(presenter: UIViewController, search: @escaping (TTY) -> Void) {
        self.presenter = presenter
        self.search = search
    }

    /// Returns the menu for `tty`, to be shown by `interaction`. Every TTY gets
    /// Search, font size, scrollback and mute; only user TTYs also get Rename,
    /// Pin or Unpin, Close, and Close All But This.
    func menu(for tty: TTY, in interaction: UIContextMenuInteraction?) -> UIMenu {
        self.interaction = interaction
        return menu(for: tty)
    }

    private func menu(for tty: TTY) -> UIMenu {
        var actions: [UIMenuElement] = []

        if !tty.isSystem {
            actions.append(
                UIAction(title: "Rename", image: UIImage(systemName: "pencil")) {
                    [weak self] _ in self?.rename(tty)
                })
            actions.append(
                tty.isPinned
                    ? UIAction(title: "Unpin", image: UIImage(systemName: "pin.slash")) {
                        [weak self] _ in self?.store.setPinned(tty, false)
                    }
                    : UIAction(title: "Pin", image: UIImage(systemName: "pin")) {
                        [weak self] _ in self?.store.setPinned(tty, true)
                    })
        }

        actions.append(
            UIAction(title: "Search", image: UIImage(systemName: "magnifyingglass")) {
                [weak self] _ in self?.search(tty)
            })

        let settings: [UIMenuElement] = [
            fontSizeMenu(for: tty),
            scrollbackMenu(for: tty),
            tty.isMuted
                ? UIAction(title: "Unmute", image: UIImage(systemName: "bell")) {
                    [weak self] _ in self?.store.setMuted(tty, false)
                }
                : UIAction(title: "Mute", image: UIImage(systemName: "bell.slash")) {
                    [weak self] _ in self?.store.setMuted(tty, true)
                },
        ]

        var sections: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: actions),
            UIMenu(options: .displayInline, children: settings),
        ]

        if !tty.isSystem {
            let others = store.othersClosed(by: tty).count
            let closeOthers = UIAction(
                title: "Close All But This", image: UIImage(systemName: "xmark.square"),
                attributes: others == 0 ? [.destructive, .disabled] : [.destructive]
            ) { [weak self] _ in self?.confirmCloseOthers(tty) }

            sections.append(
                UIMenu(
                    options: .displayInline,
                    children: [
                        UIAction(
                            title: "Close", image: UIImage(systemName: "xmark"),
                            attributes: .destructive
                        ) { [weak self] _ in self?.confirmClose(tty) },
                        closeOthers,
                    ]))
        }

        return UIMenu(title: tty.name, children: sections)
    }

    /// The range of font sizes, in points, that Smaller and Larger step within.
    private static let fontSizes = 6...40

    /// A row of Smaller, the current size, and Larger, then a Default Font Size
    /// item. The row's items keep the menu open when tapped, and each step
    /// rebuilds the menu to show the new size.
    private func fontSizeMenu(for tty: TTY) -> UIMenu {
        let size = tty.fontSize ?? AppSetting.fontSize.integer

        func change(by step: Int) -> UIAction {
            let next = size + step
            return UIAction(
                title: step < 0 ? "Smaller" : "Larger",
                image: UIImage(
                    systemName: step < 0 ? "textformat.size.smaller" : "textformat.size.larger"),
                attributes: Self.fontSizes.contains(next)
                    ? [.keepsMenuPresented] : [.keepsMenuPresented, .disabled]
            ) { [weak self] _ in
                self?.store.setFontSize(tty, next)
                self?.refreshMenu(for: tty)
            }
        }

        let current = UIAction(
            title: "\(size) pt", image: UIImage(systemName: "textformat.size"),
            attributes: [.keepsMenuPresented, .disabled]
        ) { _ in }

        let row = UIMenu(
            title: "Font Size", options: .displayInline,
            children: [change(by: -1), current, change(by: 1)])
        row.preferredElementSize = .medium

        let usesDefault = UIAction(
            title: "Default Font Size (\(AppSetting.fontSize.integer) pt)",
            state: tty.fontSize == nil ? .on : .off
        ) { [weak self] _ in self?.store.setFontSize(tty, nil) }

        return UIMenu(options: .displayInline, children: [row, usesDefault])
    }

    /// The preset scrollback lengths offered in the menu, in standard lines of
    /// 80 columns.
    private static let scrollbacks = [500, 1000, 2000, 5000, 10000]

    /// The largest custom scrollback that can be entered, in standard lines.
    /// Larger entries are reduced to it.
    static let scrollbackCeiling = 100_000

    private func scrollbackMenu(for tty: TTY) -> UIMenu {
        let lines = tty.scrollback ?? AppSetting.scrollback.integer
        let formatted = { (lines: Int) in lines.formatted() + " lines" }

        var choices: [UIMenuElement] = [
            UIAction(
                title: "Default (\(formatted(AppSetting.scrollback.integer)))",
                state: tty.scrollback == nil ? .on : .off
            ) { [weak self] _ in self?.store.setScrollback(tty, nil) }
        ]
        choices += Self.scrollbacks.map { option in
            UIAction(
                title: formatted(option), state: tty.scrollback == option ? .on : .off
            ) { [weak self] _ in self?.store.setScrollback(tty, option) }
        }

        let custom = tty.scrollback.map { !Self.scrollbacks.contains($0) } ?? false
        choices.append(
            UIAction(
                title: custom ? "Custom (\(formatted(lines)))…" : "Custom…",
                state: custom ? .on : .off
            ) { [weak self] _ in self?.askForScrollback(tty) })

        let menu = UIMenu(
            title: "Scrollback", image: UIImage(systemName: "scroll"), children: choices)
        menu.subtitle = formatted(lines)
        return menu
    }

    /// Rebuilds the visible menu after a change made from within it, so that it
    /// shows the new state without closing.
    private func refreshMenu(for tty: TTY) {
        interaction?.updateVisibleMenu { [weak self] menu in
            self?.menu(for: tty) ?? menu
        }
    }

    // MARK: Asking

    /// Asks for confirmation, then closes `tty`.
    func confirmClose(_ tty: TTY) {
        confirm(
            title: "Close \(tty.name)?",
            message: "Programs running in it keep running, and are there when it is opened again.",
            action: "Close"
        ) { [weak self] in
            self?.store.close(tty)
        }
    }

    private func confirmCloseOthers(_ tty: TTY) {
        let count = store.othersClosed(by: tty).count
        guard count > 0 else { return }

        confirm(
            title: count == 1 ? "Close 1 Other TTY?" : "Close \(count) Other TTYs?",
            message:
                "Pinned TTYs stay open. Programs running in the others keep running, and are there when they are opened again.",
            action: "Close"
        ) { [weak self] in
            self?.store.closeAll(but: tty)
        }
    }

    private func confirm(
        title: String, message: String, action: String, _ confirmed: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .destructive) { _ in confirmed() })
        presenter?.present(alert, animated: true)
    }

    private func rename(_ tty: TTY) {
        let alert = UIAlertController(
            title: "Rename \(tty.name)",
            message: "Leave it empty to go back to \(tty.defaultName).",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.text = tty.customName
            field.placeholder = tty.defaultName
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
                self?.store.rename(tty, to: alert?.textFields?.first?.text)
            })
        presenter?.present(alert, animated: true)
    }

    private func askForScrollback(_ tty: TTY) {
        let alert = UIAlertController(
            title: "Scrollback",
            message: "How many lines \(tty.name) keeps, counting each 80 columns of a long line "
                + "as one.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.text = "\(tty.scrollback ?? AppSetting.scrollback.integer)"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
                guard let text = alert?.textFields?.first?.text, let lines = Int(text) else {
                    return
                }
                self?.store.setScrollback(tty, min(max(lines, 0), Self.scrollbackCeiling))
            })
        presenter?.present(alert, animated: true)
    }
}
