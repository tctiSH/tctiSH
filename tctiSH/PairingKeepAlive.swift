//
//  PairingKeepAlive.swift
//  Keeping tctiSH running while the user is away in Settings.
//
//  Copyright © 2026 Ara Adkins.
//

import BackgroundTasks
import Foundation
import UIKit

/// Holds the app alive for the length of a pairing.
///
/// Pairing is a flow that *requires* the user to leave: the device's "Pair with
/// tctiSH" entry is in Settings, and our Bonjour advertisement has to still be
/// up when they get there.
///
/// `UIApplication.beginBackgroundTask` is the floor and buys well under a
/// minute. `BGContinuedProcessingTask` is the real answer: it exists for
/// user-initiated work that continues while they are elsewhere, and it shows
/// system UI saying so.
///
/// Both are best-effort. Nothing here fails the pairing if it cannot get an
/// assertion; the pairing simply has less time.
final class PairingKeepAlive {

    /// Also listed in `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`,
    /// without which submission is rejected.
    static let taskIdentifier = "io.ara.tctish.pairing"

    static let shared = PairingKeepAlive()

    private var assertion = UIBackgroundTaskIdentifier.invalid
    private var continued: AnyObject?
    private var isRunning = false

    private init() {}

    /// Registers the launch handler. Must run before launching finishes.
    ///
    /// Registration is separate from use: the system delivers the task through
    /// this handler rather than returning it from `submit`.
    static func register() {
        guard #available(iOS 26.0, *) else { return }

        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: DispatchQueue.main
        ) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            shared.adopt(task)
        }

        if !registered {
            Log.ui.note("pairing: could not register the keep-alive task")
        }
    }

    /// Starts holding the app alive. Callable from any thread.
    func begin(subtitle: String) {
        DispatchQueue.main.async {
            guard !self.isRunning else { return }
            self.isRunning = true

            self.assertion = UIApplication.shared.beginBackgroundTask(withName: "Pairing") {
                [weak self] in
                // Expiry means "hand it back now", not "stop pairing". The advertisement carries on
                // for as long as the system lets it.
                self?.releaseAssertion()
            }

            guard #available(iOS 26.0, *) else { return }

            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.taskIdentifier,
                title: "Pairing tctiSH",
                subtitle: subtitle)
            request.strategy = .queue

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                Log.ui.note("pairing: keep-alive was refused (\(error.localizedDescription))")
            }
        }
    }

    /// Updates what the system UI says, as the pairing moves on.
    ///
    /// Callable from any thread, and called from the handshake's: the PIN
    /// arrives on whichever thread idevice is driving pair-setup from.
    func update(subtitle: String) {
        DispatchQueue.main.async {
            guard #available(iOS 26.0, *),
                let task = self.continued as? BGContinuedProcessingTask
            else {
                return
            }
            task.updateTitle("Pairing tctiSH", subtitle: subtitle)
        }
    }

    /// Gives everything back. Callable from any thread.
    func end(success: Bool) {
        DispatchQueue.main.async {
            guard self.isRunning else { return }
            self.isRunning = false

            if #available(iOS 26.0, *) {
                if let task = self.continued as? BGContinuedProcessingTask {
                    task.setTaskCompleted(success: success)
                } else {
                    // Submitted but never launched. Left alone it stays queued, and the system can
                    // start it long after the pairing is over. `adopt` hands it straight back, but
                    // not before the user has seen the UI for it appear and go.
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
                }
            }
            self.continued = nil

            self.releaseAssertion()
        }
    }

    @available(iOS 26.0, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        // Arriving after the pairing already ended is normal as the system is under no obligation
        // to be prompt, and the right answer is to hand it straight back.
        guard isRunning else {
            task.setTaskCompleted(success: true)
            return
        }

        Log.ui.note("pairing: keep-alive granted")
        continued = task
        task.expirationHandler = { [weak self] in
            Log.ui.note("pairing: keep-alive expired")
            self?.continued = nil
        }
    }

    private func releaseAssertion() {
        guard assertion != .invalid else { return }

        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }
}
