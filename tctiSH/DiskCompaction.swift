//
//  DiskCompaction.swift
//  Shortening the disk image while Linux runs.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// The Compact Disk action.
///
/// The work itself is `QEMUInterface.compactDisk`.
enum DiskCompaction {

    enum State: Equatable {
        case idle

        /// Under way, `fraction` of the copy done once QEMU has said.
        case running(fraction: Double?)
    }

    /// Main thread only.
    private(set) static var state: State = .idle

    /// Posted on the main queue whenever `state` changes.
    static let stateDidChange = Notification.Name("io.ara.tctish.diskCompaction.stateDidChange")

    /// Why it can't start now, or nil if it can. Main thread only.
    static var refusal: String? {
        guard let app = UIApplication.shared.delegate as? AppDelegate, app.qemu != nil else {
            return "Linux isn't running."
        }
        guard state == .idle else {
            return "The disk is already being compacted."
        }
        guard ViewController.getCurrentTerminal()?.connected == true else {
            return "Linux hasn't finished starting. Try again once the terminal is up."
        }
        guard !app.machineIsAway else {
            return "Your session is being saved. Try again in a moment."
        }
        guard !Backend.isBusy else {
            return "tctiSH is switching between JIT and TCTI. Try again once it has."
        }
        return nil
    }

    /// The running disk image's length and space on disk, for the settings row.
    static var diskSizes: (length: Int64, onDisk: Int64)? {
        (UIApplication.shared.delegate as? AppDelegate)?.qemu?.diskSizes
    }

    /// Compacts the disk, and calls `completion` on the main queue with how it
    /// went. Does nothing unless `refusal` is nil. Main thread only.
    static func start(completion: @escaping (QEMUInterface.Compaction) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard refusal == nil, let qemu = (UIApplication.shared.delegate as? AppDelegate)?.qemu
        else { return }

        set(.running(fraction: nil))

        // As long as iOS allows if the app is suspended part way. The copy pauses with the process
        // when that runs out and carries on when it comes back; a session save, which waits for the
        // copy, waits with it.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Compact Disk") {
            endBackgroundTask()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var shown = -1
            let outcome = qemu.compactDisk { fraction in
                // Whole percents, so the screen isn't redrawn for every look at the job.
                let percent = Int(fraction * 100)
                guard percent != shown else { return }
                shown = percent
                DispatchQueue.main.async { set(.running(fraction: fraction)) }
            }

            DispatchQueue.main.async {
                set(.idle)
                endBackgroundTask()
                completion(outcome)
            }
        }
    }

    private static func set(_ value: State) {
        state = value
        NotificationCenter.default.post(name: stateDidChange, object: nil)
    }

    /// Main thread only.
    private static var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private static func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
