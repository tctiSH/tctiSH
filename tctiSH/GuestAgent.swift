//
//  GuestAgent.swift
//  The app's side of tctish-agent, which says whether Linux is up and does
//  what the host asks of the guest.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// Talks to `tctish-agent` in the guest, over the virtio-serial port
/// `io.ara.tctish.agent`.
///
/// It asks whether Linux is up: once after it starts, from cold or from a saved
/// session, and again after every reset. An answer means userspace is running,
/// which the app needs to know before it trusts the machine enough to save it,
/// and which clears the flag that sends a launch after a crash to a recovery
/// boot.
///
/// It also hears from the agent unasked when Linux restarts by itself, as after
/// `reboot` in the terminal: a `bye` as Linux shuts down, or failing that, a
/// `hello` from a boot it hasn't seen.
///
/// Once Linux is up, `request` asks the agent for things only the guest can do:
/// set its clock and zone, write out dirty data, trim its page cache, record
/// the command new terminals start. The agent cannot be asked to run an
/// arbitrary command.
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

    /// Why a request fails when Linux restarts before it is answered.
    static let restartReason = "Linux restarted"

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

    /// What a request was answered with.
    enum Answer {
        /// Done, with the words of the answer after its id.
        case done([Substring])

        /// Not done, and why.
        case failed(String)
    }

    /// The id for the next request. Never reused, and started at random each
    /// launch, so that an answer from before a reset, or from the last launch,
    /// can't be taken for an answer to a newer request.
    private var nextRequestID = Int.random(in: 1...1_000_000_000)

    /// The requests waiting for an answer, by id.
    private var waiting: [Int: (Answer) -> Void] = [:]

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
        failWaitingRequests(because: Self.restartReason)
        keepAsking()
    }

    /// Asks the agent to do `operation` with `arguments`, and calls `answered`
    /// with the answer on the main queue.
    ///
    /// Only while Linux is up and the agent is connected; otherwise the answer
    /// is `.failed` at once. Arguments can't contain spaces. There's no timeout
    /// here: a caller that can't wait indefinitely sets a deadline, as
    /// `requestWaiting` does. A restart fails every request still waiting.
    func request(
        _ operation: String, _ arguments: String..., answered: @escaping (Answer) -> Void
    ) {
        request(operation, arguments: arguments, answered: answered)
    }

    /// `request` for a thread other than the main one: asks, and waits for the
    /// answer until `deadline`. Nil if none came by then; a later answer is
    /// discarded.
    func requestWaiting(
        until deadline: DispatchTime, _ operation: String, _ arguments: String...
    ) -> Answer? {
        dispatchPrecondition(condition: .notOnQueue(.main))

        final class Box {
            var answer: Answer?
        }
        let box = Box()
        let answered = DispatchSemaphore(value: 0)

        DispatchQueue.main.async { [self] in
            request(operation, arguments: arguments) { answer in
                box.answer = answer
                answered.signal()
            }
        }

        guard answered.wait(timeout: deadline) == .success else { return nil }
        return box.answer
    }

    /// `request`, with the arguments as an array.
    func request(
        _ operation: String, arguments: [String], answered: @escaping (Answer) -> Void
    ) {
        guard isUp, socket.isConnected else {
            answered(.failed("the agent isn't connected"))
            return
        }
        guard
            !arguments.contains(where: { $0.isEmpty || $0.contains(where: \.isWhitespace) })
        else {
            assertionFailure("agent: an argument to '\(operation)' is empty or has a space")
            answered(.failed("a bad argument"))
            return
        }

        let id = nextRequestID
        nextRequestID += 1
        waiting[id] = answered

        let words = [operation, String(id)] + arguments
        socket.send(Array((words.joined(separator: " ") + "\n").utf8))
    }

    private func failWaitingRequests(because reason: String) {
        let failed = waiting
        waiting.removeAll()
        for answered in failed.values {
            answered(.failed(reason))
        }
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

        case ("hello", 2) where words[1] == bootID:
            // The agent restarted within the same boot (it was killed, say), so it won't answer
            // anything asked before.
            failWaitingRequests(because: "the agent restarted")

        case ("hello", 2), ("bye", 2):
            // From before a reset.
            break

        case ("done", 2...):
            requestAnswered(id: words[1], with: .done(Array(words.dropFirst(2))))

        case ("error", 2...):
            requestAnswered(id: words[1], with: .failed(words.dropFirst(2).joined(separator: " ")))

        default:
            Log.network.warn("agent: unexpected answer '\(answer.prefix(80))'")
        }
    }

    private func requestAnswered(id: Substring, with answer: Answer) {
        // An answer to a request from before a reset, or to none at all.
        guard let id = Int(id), let answered = waiting.removeValue(forKey: id) else {
            Log.network.warn("agent: an answer to no waiting request (\(id))")
            return
        }
        answered(answer)
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
