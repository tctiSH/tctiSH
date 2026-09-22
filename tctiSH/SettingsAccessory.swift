//
//  SettingsAccessory.swift
//  Where the in-app settings sheet is reached from.
//
//  Copyright © 2026 Ara Adkins.
//

import SwiftTerm
import UIKit

/// The keyboard accessory bar, with a way into settings on the end of it.
///
/// Composed around SwiftTerm's `TerminalAccessory` rather than modifying it.
/// That bar is expected to be replaced, so nothing here reaches into its
/// internals, overrides its layout, or depends on which buttons it puts where:
/// it is hosted as an opaque subview, and this file owns only the strip to the
/// right of it.
final class SettingsAccessory: UIInputView {

    /// How wide the settings button's strip is.
    private static let buttonWidth: CGFloat = 44

    /// How tall the bar is, matching what SwiftTerm builds for itself.
    private static var height: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone ? 36 : 48
    }

    /// The bar this wraps.
    ///
    /// Exposed because SwiftTerm reads the Ctrl key's state from the terminal's
    /// accessory view, and finds it only if that view *is* a
    /// `TerminalAccessory`. Wrapped, it is not, so the terminal has to be told
    /// where the bar went. See `TctiTermView.insertText(_:)`.
    let terminalAccessory: TerminalAccessory

    private let button = UIButton(type: .system)
    private let present: () -> Void

    /// Replaces a terminal's accessory bar with one that also offers settings.
    ///
    /// Returns without doing anything if the terminal isn't using SwiftTerm's
    /// own bar.
    static func install(on terminal: TerminalView, present: @escaping () -> Void) {
        guard terminal.inputAccessoryView is TerminalAccessory else { return }

        // Built fresh rather than rehosting the existing one, and deliberately `.default` rather
        // than `.keyboard`: the bar's background is drawn once, by the container below, so an inner
        // view drawing its own would show as a seam where the two meet.
        let accessory = TerminalAccessory(
            frame: CGRect(x: 0, y: 0, width: terminal.frame.width, height: height),
            inputViewStyle: .default,
            container: terminal)

        terminal.inputAccessoryView = SettingsAccessory(wrapping: accessory, present: present)
    }

    private init(wrapping inner: TerminalAccessory, present: @escaping () -> Void) {
        self.terminalAccessory = inner
        self.present = present

        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.height),
            inputViewStyle: .keyboard)

        allowsSelfSizing = true

        button.setImage(UIImage(systemName: "gearshape"), for: .normal)
        button.accessibilityLabel = "Settings"
        button.addAction(UIAction { [weak self] _ in self?.present() }, for: .touchUpInside)

        addSubview(inner)
        addSubview(button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this bar is built in code")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    /// Lays the bar out by frame rather than by constraints.
    ///
    /// `TerminalAccessory` sizes and rebuilds itself from its own bounds, and
    /// giving it a frame is how it expects to be told how much room it has.
    override func layoutSubviews() {
        super.layoutSubviews()

        let content = bounds.inset(
            by: UIEdgeInsets(
                top: 0, left: safeAreaInsets.left, bottom: 0, right: safeAreaInsets.right))

        button.frame = CGRect(
            x: content.maxX - Self.buttonWidth,
            y: content.minY,
            width: Self.buttonWidth,
            height: content.height)

        terminalAccessory.frame = CGRect(
            x: content.minX,
            y: content.minY,
            width: max(0, content.width - Self.buttonWidth),
            height: content.height)
    }
}
