//
//  TctiApplication.swift
//  The application, which sees every key before whatever has the keyboard.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// tctiSH's `UIApplication`, named in Info.plist as the principal class.
///
/// It currently exists to handle Esc actions in a consistent and global way.
@objc(TctiApplication)
final class TctiApplication: UIApplication {

    /// Set once an Esc has closed something, so that its release is kept back
    /// as well, rather than reaching the terminal unpaired.
    private var heldEscape = false

    override func sendEvent(_ event: UIEvent) {
        if let presses = event as? UIPressesEvent, takeEscape(presses) {
            return
        }
        super.sendEvent(event)
    }

    /// Whether the event was an Esc for More or Settings, which is then dealt
    /// with here.
    private func takeEscape(_ event: UIPressesEvent) -> Bool {
        let changing = event.allPresses.filter {
            $0.phase == .began || $0.phase == .ended || $0.phase == .cancelled
        }
        guard changing.count == 1, let press = changing.first, Self.isEscape(press) else {
            return false
        }

        if press.phase == .began {
            let bar = (ViewController.getCurrent() as? ViewController)?.keyBar
            if bar?.isMenuOpen == true {
                bar?.closeMenu()
            } else if !SettingsViewController.closeForEscape() {
                heldEscape = false
                return false
            }

            heldEscape = true
            return true
        }

        defer { heldEscape = false }
        return heldEscape
    }

    private static func isEscape(_ press: UIPress) -> Bool {
        press.key?.keyCode == .keyboardEscape
            || press.key?.charactersIgnoringModifiers == UIKeyCommand.inputEscape
    }
}
