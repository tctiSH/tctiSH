//
//  GuestAgent.swift
//  The app's side of tctish-agent, which says whether what arrivesLinux is up.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// Talks to `tctish-agent` in the guest, over a virtio-serial port of its own.
///
/// For now it asks only whether Linux is up: once after it starts, from cold or
/// from a saved session, and again after every reset. An answer means userspace
/// is running, which is what the app needs to know before it trusts the machine
/// enough to save it, and what clears the flag that sends a launch after a
/// crash to a recovery boot.
///
/// It also hears from the agent unasked when Linux restarts by itself, as after
/// `reboot` in the terminal: a `bye` as Linux shuts down, or failing that, a
/// `hello` from a boot it hasn't seen.
///
/// Use it from the main thread.
final class GuestAgent {

    static let shared = GuestAgent()

    /// Posted on the main queue when Linux has answered, after a launch or a
    /// reset.
    static let linuxDidComeUp = Notification.Name("io.ara.tctish.linuxDidComeUp")

    /// How often to ask while Linux hasn't answered.
    private static let askingInterval: TimeInterval = 1

    /// The longest line from the agent that is kept. It only ever sends short
    /// ones; anything longer is not the agent.
    private static let maxLine = 4096

    /// Whether Linux has answered since it was last started.
    private(set) var isUp = false

    private let socket = ChardevSocket(path: QEMUInterface.agentSocketPath, name: "agent")

    /// Which boot of Linux answered, from `/proc/sys/kernel/random/boot_id`, or
    /// nil until one has.
    private var bootID: Substring?

    /// Which round of asking this is. Each start of Linux begins a new one, so
    /// that an answer still on its way from before a reset isn't taken as an
    /// answer from after it.
    private var round = 0

    private var askingTimer: Timer?
    private var line: [UInt8] = []

    private init() {
        socket.onConnect = { [unowned self] in ask() }
        socket.onReceive = { [unowned self] bytes in received(bytes) }
    }

    /// Connects to the agent, and asks until Linux answers.
    func start() {
        socket.start()
        keepAsking()
    }

    /// Linux is being started again, by a reset: it is no longer known to be
    /// up, and is asked again until it answers.
    func linuxRestarting() {
        isUp = false
        bootID = nil
        round += 1
        keepAsking()
    }

    private func keepAsking() {
        guard !isUp, askingTimer == nil else { return }

        ask()
        let timer = Timer(timeInterval: Self.askingInterval, repeats: true) { [weak self] _ in
            self?.ask()
        }
        RunLoop.main.add(timer, forMode: .common)
        askingTimer = timer
    }

    /// Asks once. Asked while the guest isn't reading yet, the question waits
    /// in the socket and is answered when the agent starts.
    private func ask() {
        // Not while a question is still waiting to go: a guest that never reads would have them
        // pile up behind it for as long as it doesn't.
        guard !isUp, socket.isConnected, socket.unsentCount == 0 else { return }
        socket.send(Array("ping \(round)\n".utf8))
    }

    private func received(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            guard byte != UInt8(ascii: "\n") else {
                answered(String(decoding: line, as: UTF8.self))
                line.removeAll(keepingCapacity: true)
                continue
            }
            if line.count < Self.maxLine {
                line.append(byte)
            }
        }
    }

    private func answered(_ answer: String) {
        let words = answer.split(separator: " ")
        switch (words.first, words.count) {
        case ("pong", 3):
            ponged(round: Int(words[1]), bootID: words[2])

        case ("hello", 2) where bootID != nil && words[1] != bootID:
            // A boot that didn't say bye on its way down, as after `reboot -f`.
            linuxRestartedItself(saying: "hello from a new boot")

        case ("bye", 2) where words[1] == bootID:
            linuxRestartedItself(saying: "bye")

        case ("hello", 2), ("bye", 2):
            // The boot already known, or one from before a reset.
            break

        default:
            Log.network.warn("agent: unexpected answer '\(answer.prefix(80))'")
        }
    }

    /// Linux is going down, or has come back up, without the app having asked:
    /// it is no longer known to be up, and is treated as a reset would be.
    private func linuxRestartedItself(saying what: String) {
        Log.network.note("agent: \(what); Linux is restarting by itself")
        guard let qemu = (UIApplication.shared.delegate as? AppDelegate)?.qemu else {
            linuxRestarting()
            return
        }
        qemu.linuxRestartingItself()
    }

    private func ponged(round answered: Int?, bootID: Substring) {
        // An answer to an earlier round, or another answer to this one.
        guard !isUp, answered == round else { return }

        isUp = true
        self.bootID = bootID
        askingTimer?.invalidate()
        askingTimer = nil
        Log.network.note("agent: linux is up, at \(AppDelegate.sinceLaunch()) since launch")

        // The boot, or the resume, worked; a crash from here on is not the boot's fault.
        UserDefaults.standard.set(false, forKey: "attempting_boot")

        NotificationCenter.default.post(name: Self.linuxDidComeUp, object: self)
    }
}
