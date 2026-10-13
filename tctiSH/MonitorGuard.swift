//
//  MonitorGuard.swift
//  Asking before VM Management runs a command that pulls the VM out from under the app.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import SwiftTerm

// MARK: - The gate

/// Stands between VM Management and QEMU's monitor, and asks before a Return
/// submits a command that `MonitorGuard` flags.
///
/// A Return is looked at only once the monitor has echoed what was typed before
/// it, since the line is read off the screen, and nothing typed later overtakes
/// it while it waits or while the question is open: what follows a Return goes
/// in order behind it, and is dropped with it if the answer is no.
///
/// Use it from the main thread.
final class MonitorGate {

    /// How long a Return waits for the monitor to echo what was sent before it.
    /// The monitor stays silent while QEMU is busy, as with a save or a
    /// return from the background, and for keys that change nothing on screen;
    /// past this, what was typed stands in for the screen.
    private static let echoWait: TimeInterval = 0.5

    /// Asks whether to submit a flagged command, and calls back with the
    /// answer. It must call back, or VM Management stops sending.
    var confirm: ((MonitorGuard.Risk, @escaping (Bool) -> Void) -> Void)?

    private let deliver: (ArraySlice<UInt8>) -> Void
    private let screen: () -> Terminal?

    /// Sends waiting their turn, split so that each holds at most one Return,
    /// at its end.
    private var queue: [ArraySlice<UInt8>] = []

    /// What has been sent since the last Return.
    private var typed: [UInt8] = []

    /// Whether something has been sent that the monitor hasn't answered with
    /// output yet.
    private var echoOwed = false
    private var echoTimer: Timer?
    private var asking = false

    /// `screen` is the terminal showing the monitor, and `deliver` sends to it.
    init(screen: @escaping () -> Terminal?, deliver: @escaping (ArraySlice<UInt8>) -> Void) {
        self.screen = screen
        self.deliver = deliver
    }

    func send(_ data: ArraySlice<UInt8>) {
        queue += MonitorGuard.lines(in: data)
        drain()
    }

    /// The monitor said something.
    func received() {
        echoOwed = false
        guard let echoTimer else { return }
        echoTimer.invalidate()
        self.echoTimer = nil
        drain()
    }

    /// A connection to the monitor was made. QEMU keeps a line typed before a
    /// reconnection but shows a bare prompt, so a Return would submit text that
    /// isn't on screen: go to the end of the line and erase it.
    func connected() {
        typed.removeAll()
        echoOwed = false
        deliver([0x05, 0x15])
    }

    private func drain() {
        while !asking, echoTimer == nil, let next = queue.first {
            if MonitorGuard.submits(next) {
                if echoOwed {
                    waitForEcho()
                    return
                }
                if let confirm,
                    let risk = MonitorGuard.risk(submitting: next, in: screen(), after: typed)
                {
                    asking = true
                    confirm(risk) { [weak self] submit in
                        guard let self else { return }
                        asking = false
                        if submit {
                            queue.removeFirst()
                            pass(next)
                        } else {
                            // The command stays typed; what was sent behind it goes.
                            queue.removeAll()
                        }
                        drain()
                    }
                    return
                }
            }
            queue.removeFirst()
            pass(next)
        }
    }

    private func waitForEcho() {
        let timer = Timer(timeInterval: Self.echoWait, repeats: false) { [weak self] _ in
            guard let self else { return }
            echoTimer = nil
            echoOwed = false
            drain()
        }
        RunLoop.main.add(timer, forMode: .common)
        echoTimer = timer
    }

    private func pass(_ data: ArraySlice<UInt8>) {
        if MonitorGuard.submits(data) {
            typed.removeAll()
        } else {
            typed += data
        }
        echoOwed = true
        deliver(data)
    }
}

// MARK: - The commands

/// Decides which monitor commands typed into VM Management are asked about
/// before they are submitted.
///
/// The monitor's line editing happens in QEMU, which echoes what is typed, so
/// the line being submitted is read off the screen when Return is pressed. That
/// includes a line recalled from history or finished by tab completion, neither
/// of which the app sees typed. What was typed is checked as well, for when the
/// screen hasn't caught up.
enum MonitorGuard {

    /// What submitting a command would do, as an alert puts it.
    struct Risk {
        let title: String
        let message: String
        let action: String
    }

    /// The prompt QEMU's monitor ends each of its prompts with.
    private static let prompt = "(qemu) "

    private static let returns: Set<UInt8> = [0x0d, 0x0a]

    /// `data` split after each Return, so that each piece submits at most one
    /// line.
    static func lines(in data: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var pieces: [ArraySlice<UInt8>] = []
        var start = data.startIndex
        for index in data.indices where returns.contains(data[index]) {
            pieces.append(data[start...index])
            start = index + 1
        }
        if start < data.endIndex {
            pieces.append(data[start...])
        }
        return pieces
    }

    /// Whether `piece`, one of `lines(in:)`, submits a line.
    static func submits(_ piece: ArraySlice<UInt8>) -> Bool {
        piece.last.map(returns.contains) ?? false
    }

    /// The risk of the line `piece` submits, if any: `piece` is one of
    /// `lines(in:)`, `terminal` shows the monitor, and `typed` is what was sent
    /// since the last Return.
    static func risk(
        submitting piece: ArraySlice<UInt8>, in terminal: Terminal?, after typed: [UInt8]
    ) -> Risk? {
        guard submits(piece) else { return nil }
        let body = Array(piece.dropLast())

        // The line on screen, with what comes before the Return typed onto its end.
        if let terminal, let risk = risk(of: edited(Array(onScreen(in: terminal).utf8) + body)) {
            return risk
        }

        // What was typed, for when the screen is behind: the monitor hadn't echoed it yet, or the
        // screen was read late. Only when it can be followed without the screen: keys that move the
        // cursor, recall history or complete leave the line to the monitor.
        let keys = typed + body
        if followable(keys), let risk = risk(of: edited(keys)) {
            return risk
        }
        return nil
    }

    /// Whether the line `keys` make can be worked out from the keys alone:
    /// printable characters, Backspace, and Ctrl-U and Ctrl-W, which erase back
    /// from the cursor.
    private static func followable(_ keys: [UInt8]) -> Bool {
        keys.allSatisfy { $0 >= 0x20 || [0x08, 0x15, 0x17].contains($0) }
    }

    /// The line typing `keys` at the end of a line makes, as the monitor would
    /// edit it, with escape sequences left out.
    private static func edited(_ keys: [UInt8]) -> String {
        var line: [UInt8] = []

        // 1 after ESC, 2 inside a CSI or SS3 sequence.
        var escape = 0
        for key in keys {
            switch (escape, key) {
            case (1, UInt8(ascii: "[")), (1, UInt8(ascii: "O")):
                escape = 2
            case (1, _):
                escape = 0
            case (2, 0x40...0x7e):
                escape = 0
            case (2, _):
                continue
            case (_, 0x1b):
                escape = 1
            case (_, 0x7f), (_, 0x08):
                // One byte, as the monitor does, even of a character that takes several.
                _ = line.popLast()
            case (_, 0x15):
                line.removeAll()
            case (_, 0x17):
                while line.last == UInt8(ascii: " ") { line.removeLast() }
                while let last = line.last, last != UInt8(ascii: " ") { line.removeLast() }
            case (_, 0x00..<0x20):
                continue
            default:
                line.append(key)
            }
        }
        return String(decoding: line, as: UTF8.self)
    }

    /// The command on the cursor's line, after the monitor's prompt, or nothing
    /// if the line has no prompt.
    ///
    /// SwiftTerm scrolls to the cursor before it sends what is typed, so the
    /// cursor's row is on screen; read later, as after waiting for an echo, it
    /// still is unless the terminal was scrolled meanwhile. A line too long for
    /// the screen goes on in the rows below it, which SwiftTerm marks as
    /// wrapped, and can start above the screen. Such a line is a best guess:
    /// the monitor redraws a line as it is edited by moving the cursor left,
    /// which stops at the screen's edge, so past the first row it draws the
    /// line again rather than over itself. The command, the first word after
    /// the prompt, is still read right.
    private static func onScreen(in terminal: Terminal) -> String {
        // Rows by their place in the whole buffer, scrollback included.
        let top = terminal.buffer.totalLinesTrimmed + terminal.getTopVisibleRow()
        let cursor = top + terminal.getCursorLocation().y
        guard var line = terminal.getScrollInvariantLine(row: cursor) else { return "" }

        // The rows above that the cursor's continues, then the ones below that continue it, as the
        // cursor can have been moved back into the middle of the line. Within reason.
        var text = line.translateToString()
        var row = cursor
        while line.isWrapped, cursor - row < maxRows,
            let above = terminal.getScrollInvariantLine(row: row - 1)
        {
            text = above.translateToString() + text
            line = above
            row -= 1
        }
        row = cursor + 1
        while row - cursor < maxRows, let below = terminal.getScrollInvariantLine(row: row),
            below.isWrapped
        {
            text += below.translateToString()
            row += 1
        }

        // Cells nothing was written to read as NUL.
        text = String(text.map { $0 == "\0" ? " " : $0 })
        text = String(text.reversed().drop(while: \.isWhitespace).reversed())

        guard let start = text.range(of: prompt, options: .backwards) else { return "" }
        return String(text[start.upperBound...])
    }

    /// The most rows of one line looked at either side of the cursor's.
    private static let maxRows = 64

    /// The risk of submitting `line`, if it is one of the commands asked about.
    static func risk(of line: String) -> Risk? {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard let command = words.first else { return nil }

        switch command {
        case "quit", "q":
            return Risk(
                title: "Quit QEMU?",
                message:
                    "Linux stops at once, without shutting down, and tctiSH has to be opened again. "
                    + "It then resumes the last saved session, and the disk goes back to that "
                    + "moment with it.",
                action: "Quit")

        case "system_powerdown":
            return Risk(
                title: "Shut Down Linux?",
                message:
                    "QEMU ends once Linux has shut down, and tctiSH has to be opened again. Linux "
                    + "starts afresh then.",
                action: "Shut Down")

        case "system_reset":
            return Risk(
                title: "Reset the Machine?",
                message:
                    "Linux starts again at once, without shutting down. Everything running in it "
                    + "ends, and anything it hadn't written to the disk is lost.",
                action: "Reset")

        case "stop", "s":
            return Risk(
                title: "Pause Linux?",
                message: "Linux and every TTY stop until `cont`, or `c`, is typed here.",
                action: "Pause")

        case "loadvm":
            return Risk(
                title: "Load a Snapshot?",
                message:
                    "Linux and the disk go back to the snapshot's moment. Everything since is lost.",
                action: "Load")

        case "delvm", "snapshot_delete_blkdev_internal":
            return Risk(
                title: "Delete a Snapshot?",
                message:
                    "If it is the saved session tctiSH resumes, the next launch starts Linux afresh.",
                action: "Delete")

        case "savevm"
        where words.count > 1 && QEMUInterface.ownedSnapshotTags.contains(String(words[1])):
            return Risk(
                title: "Replace tctiSH's Snapshot?",
                message:
                    "tctiSH saves and resumes sessions as \(words[1]) itself. Saving over it here "
                    + "can change what the next launch resumes.",
                action: "Replace")

        case "device_add":
            return Risk(
                title: "Add to the Machine?",
                message:
                    "tctiSH resumes sessions into the machine it starts with, so a session saved "
                    + "with this added can't be resumed. Change vCPUs in Settings instead.",
                action: "Add")

        case "device_del", "drive_del", "netdev_del", "object_del", "chardev-remove",
            "chardev-change":
            return Risk(
                title: "Remove Part of the Machine?",
                message:
                    "Linux can lose its disk or network, and tctiSH its terminals or its line to "
                    + "Linux, until tctiSH is opened again. Change vCPUs in Settings instead.",
                action: "Remove")

        case "snapshot_blkdev", "drive_mirror", "block_job_complete":
            return Risk(
                title: "Move the Disk?",
                message:
                    "Linux's disk can end up in another file, which tctiSH won't open next time. "
                    + "What Linux writes from then on, and the sessions tctiSH saves, go there.",
                action: "Continue")

        case "qemu-io":
            return Risk(
                title: "Change the Disk Directly?",
                message: "Writing to the disk behind Linux's back can corrupt its filesystem.",
                action: "Continue")

        case "balloon":
            return Risk(
                title: "Take Memory from Linux?",
                message: "With too little, Linux starts ending programs to make room.",
                action: "Continue")

        case "tcg_switch", "park", "unpark":
            return Risk(
                title: "Do tctiSH's Job by Hand?",
                message:
                    "tctiSH switches backends and parks the VM itself, preparing for each first. "
                    + "Done here, it can leave Linux stopped or crash the app.",
                action: "Continue")

        default:
            return nil
        }
    }
}
