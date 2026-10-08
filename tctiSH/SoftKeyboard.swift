//
//  SoftKeyboard.swift
//  The software keyboard's Shift, which iOS doesn't tell apps about.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// The software keyboard's Shift key.
///
/// It is read from `UIKeyboardImpl`, UIKit's keyboard controller, which is a
/// private API. tctiSH is only ever sideloaded, as `JITHelperLauncher.h`
/// explains, so that is a cost it can bear.
enum SoftKeyboard {

    private static let activeInstance = NSSelectorFromString("activeInstance")
    private static let isShiftedSelector = NSSelectorFromString("isShifted")
    private static let isShiftLockedSelector = NSSelectorFromString("isShiftLocked")
    private static let setShiftSelector = NSSelectorFromString("setShift:")

    /// UIKit's keyboard controller, while there is one.
    private static var keyboard: NSObject? {
        guard let type = NSClassFromString("UIKeyboardImpl"),
            (type as AnyObject).responds(to: activeInstance)
        else { return nil }

        return (type as AnyObject).perform(activeInstance)?.takeUnretainedValue() as? NSObject
    }

    /// Whether the software keyboard's Shift is on, or its caps lock.
    static var isShifted: Bool {
        guard let keyboard, keyboard.responds(to: isShiftedSelector) else { return false }

        // Through key-value coding rather than `perform`, which can't return a BOOL. The key is
        // only asked for once the getter is known to be there, as a missing one would throw.
        return (keyboard.value(forKey: "shifted") as? Bool) ?? false
    }

    /// Whether the software keyboard's caps lock is on: Shift tapped twice, to
    /// stay on.
    static var isShiftLocked: Bool {
        guard let keyboard, keyboard.responds(to: isShiftLockedSelector) else { return false }
        return (keyboard.value(forKey: "shiftLocked") as? Bool) ?? false
    }

    /// Lets go of Shift once a key from the bar has used it, as the keyboard
    /// does itself after a letter. Not caps lock, which stays on until it's
    /// turned off.
    static func releaseShift() {
        guard isShifted, !isShiftLocked, let keyboard, keyboard.responds(to: setShiftSelector)
        else { return }

        keyboard.setValue(false, forKey: "shift")
    }
}
