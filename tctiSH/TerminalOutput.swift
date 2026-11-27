//
//  TerminalOutput.swift
//  Parses a terminal's output off the main thread.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import SwiftTerm

/// Parses what a transport reads for one terminal into that terminal, on
/// `queue`, off the main thread. Heavy output then doesn't hold up the UI, and
/// a busy UI doesn't hold up the guest.
///
/// After parsing, it tells the main thread with one notice, however many chunks
/// were parsed since the last one.
///
/// One reader delivers chunks on `queue`, one at a time. `state` is guarded by
/// `lock`; `terminal` and `onReceived` are main-thread only.
final class TerminalOutput: @unchecked Sendable {

    /// The queue output is read and parsed on. It runs at the main thread's
    /// priority because the main thread can wait for the terminal's lock while
    /// a parse here holds it, and the lock doesn't raise the parse's priority.
    let queue: DispatchQueue

    init(name: String) {
        queue = DispatchQueue(label: "io.ara.tctish.output.\(name)", qos: .userInteractive)
    }

    /// The most bytes parsed under one hold of the terminal's lock, so that the
    /// main thread never waits long for it.
    private static let pieceSize = 8 * 1024

    private struct State {
        /// Feeds `terminal`, or nil while there is none.
        var feeder: TerminalFeedSender?

        /// Whether a notice is already queued on the main thread.
        var noticeWaiting = false

        /// Whether anything but bells was parsed since the last notice.
        var hadOutput = false
    }

    private let lock = NSLock()
    private var state = State()

    /// The terminal the output is parsed into.
    weak var terminal: TctiTermView? {
        didSet {
            dispatchPrecondition(condition: .onQueue(.main))
            let feeder = terminal?.feedSender
            lock.withLock { state.feeder = feeder }
        }
    }

    /// Called with each notice, even while there is no terminal.
    var onReceived: (() -> Void)?

    /// Parses `bytes` into the terminal, or drops them if there is none. Called
    /// on `queue`.
    func deliver(_ bytes: ArraySlice<UInt8>) {
        let feeder = lock.withLock { state.feeder }
        if let feeder {
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let end = min(start + Self.pieceSize, bytes.endIndex)
                feeder.feed(byteArray: bytes[start..<end])
                start = end
            }
        }
        noteParsed(hadOutput: feeder != nil && Self.isOutput(bytes))
    }

    /// Whether `bytes` hold anything but BEL. A TTY's status shows a bell
    /// differently from new output.
    private static func isOutput(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.contains { $0 != 0x07 }
    }

    /// Queues a notice to the main thread, unless one is already queued.
    private func noteParsed(hadOutput: Bool) {
        let post = lock.withLock {
            state.hadOutput = state.hadOutput || hadOutput
            let post = !state.noticeWaiting
            state.noticeWaiting = true
            return post
        }
        guard post else { return }

        DispatchQueue.main.async { [self] in
            let hadOutput = lock.withLock {
                let hadOutput = state.hadOutput
                state.noticeWaiting = false
                state.hadOutput = false
                return hadOutput
            }
            terminal?.outputParsed(hadOutput: hadOutput)
            onReceived?()
        }
    }
}
