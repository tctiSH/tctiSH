//
//  PairableHostPairing.swift
//  Advertises tctiSH as a computer this device can pair with.
//
//  Copyright © 2026 Ara Adkins.
//

import Darwin
import Foundation
import StikJIT

/// Runs a single device-initiated pairing, start to finish.
///
/// The user's half of this happens in Settings, not here as tctiSH puts up a
/// Bonjour advertisement, the user finds it under the device's pairing screen,
/// and we display the PIN they then have to type. This is long-lived and
/// interactive rather than a call that returns a value, and it has to survive
/// the app being backgrounded while the user walks through the flow.
///
/// Lives in the app because advertising needs the app's `NSBonjourServices` and
/// its local-network permission, because an accepted socket cannot cross the
/// extension boundary, and because the app is the thing with background modes
/// that stays alive while the user is in Settings.
final class PairableHostPairing: NSObject {

    enum Outcome {
        case paired(Data)
        case cancelled
        case failed(reason: String)
    }

    /// How long to advertise before giving up.
    static let deadline: TimeInterval = 300

    /// What the device is told it is pairing with.
    ///
    /// The model is a Mac identifier on purpose as iOS treats the host in this
    /// exchange as a computer, and shows both of these to the user.
    static let hostName = "tctiSH"
    static let hostModel = "Mac17,7"

    private let onPIN: (String) -> Void
    private let onOutcome: (Outcome) -> Void

    private var host: PairableHost?
    private var service: NetService?

    /// The listening socket, owned by the wait.
    ///
    /// Deliberately not shared: it is opened on the main thread before the wait
    /// is dispatched, and from then until the wait returns nothing else touches
    /// it. Closing a descriptor from another thread races against the syscall
    /// the wait is about to make on it.
    private var listener: Int32 = -1

    /// The accepted connection, while a handshake is running on it.
    ///
    /// This one *is* shared, because `cancel()` has to reach it. Guarded by
    /// `lock`, and only ever shut down rather than closed.
    private var connection: Int32 = -1

    /// What the local-network probe made of things, kept for the failure
    /// message. Written on the main thread before the wait is dispatched.
    private var localNetworkLooksUsable = true

    private let lock = NSLock()
    private var isFinished = false
    private var isCancelled = false

    init(
        onPIN: @escaping (String) -> Void,
        onOutcome: @escaping (Outcome) -> Void
    ) {
        self.onPIN = onPIN
        self.onOutcome = onOutcome
    }

    /// Safe despite the wait owning the listener: the wait holds a strong
    /// reference to this object for as long as it runs, so this cannot happen
    /// underneath it. It matters only when the wait never started.
    deinit {
        closeListener()
    }

    // MARK: - Running

    /// Begins advertising. Call on the main thread.
    ///
    /// `NetService` publishes against the current run loop, and the main one is
    /// the only one guaranteed to be running, so the advertisement is set up
    /// here and only the blocking accept goes to a background queue.
    func start() {
        // Asked for first. Publishing a Bonjour service does not reliably raise the local-network
        // prompt, and a publish the user has not permitted still reports success.
        PairingKeepAlive.shared.begin(subtitle: "Waiting for this device to connect")

        LocalNetworkPermission.request { [weak self] granted in
            guard let self else { return }

            // Advertising anyway, because the probe has a false negative in it: a slow responder
            // looks the same as a refusal. Remembered rather than acted on, so that if nothing does
            // turn up we can say what we suspect.
            self.localNetworkLooksUsable = granted
            if !granted {
                Log.network.note("pairing: local network unavailable; advertising anyway")
            }
            self.advertise()
        }
    }

    /// Generates the identity, opens the listener and publishes.
    private func advertise() {
        // The permission probe takes up to thirty seconds, and the first time through most of that
        // is the user reading a system dialog. A cancellation landing before this runs is an
        // ordinary thing to do, not a corner case, and without this guard it would leave an
        // advertisement up pointing at a listener the wait has already closed.
        guard !shouldStop else { return }

        let host: PairableHost
        do {
            host = try PairableHost(name: Self.hostName, model: Self.hostModel)
        } catch {
            finish(.failed(reason: error.localizedDescription))
            return
        }
        self.host = host

        let port: UInt16
        do {
            port = try openListener()
        } catch {
            finish(.failed(reason: error.localizedDescription))
            return
        }

        Log.network.note(
            "pairing: advertising \(host.serviceIdentifier) on port \(port) "
                + "with \(host.txtRecords.count) TXT records")

        // An empty domain rather than "local.", and a type with its trailing dot, which is the form
        // NetService documents and the form a known-working implementation uses. The first attempt
        // used "local." and no trailing dot: it published successfully and the device never saw it.
        let service = NetService(
            domain: "",
            type: "\(PairableHost.serviceType).",
            name: host.serviceIdentifier,
            port: Int32(port))
        service.delegate = self
        service.setTXTRecord(
            NetService.data(fromTXTRecord: host.txtRecords.mapValues { Data($0.utf8) }))
        service.publish()
        self.service = service

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.waitForDevice(host: host)
        }
    }

    /// Stops advertising and abandons the wait. Call on the main thread.
    ///
    /// `advertise()` decides whether to publish at all by reading the flag this
    /// sets, and the two sharing a queue is what makes that a decision rather
    /// than a race.
    ///
    /// Returns immediately; the wait itself notices within a second, on its
    /// next time round the poll. The advertisement goes at once, because
    /// `finish` stops the `NetService`, so there is nothing for the user to see
    /// in the meantime.
    func cancel() {
        lock.lock()
        isCancelled = true

        // Once a device has connected the wait is inside `accept(fileDescriptor:)`, which blocks
        // and takes no cancellation token, so breaking its socket is the only way to bring it back.
        //
        // `shutdown` rather than `close`: the handshake is working on a dup of this descriptor, and
        // only shutting the socket down reaches both. Closing it here would also hand the number
        // straight back to the process while the wait still believes in it.
        if connection >= 0 { shutdown(connection, SHUT_RDWR) }
        lock.unlock()

        finish(.cancelled)
    }

    // MARK: - The wait

    /// Blocks until a device connects, the deadline passes, or we are
    /// cancelled.
    private func waitForDevice(host: PairableHost) {
        let started = Date()

        while true {
            // Checked here to ensure that the listener is safe to own privately.
            if shouldStop {
                closeListener()
                return
            }

            let remaining = Self.deadline - Date().timeIntervalSince(started)
            guard remaining > 0 else {
                closeListener()
                finish(.failed(reason: Self.timeoutReason(localNetworkLooksUsable)))
                return
            }

            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))

            if ready < 0 {
                if errno == EINTR { continue }
                closeListener()
                finish(.failed(reason: "poll() failed: \(String(cString: strerror(errno)))"))
                return
            }
            if ready == 0 { continue }

            let connection = accept(listener, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                closeListener()
                finish(.failed(reason: "accept() failed: \(String(cString: strerror(errno)))"))
                return
            }

            Log.network.note("pairing: a device connected; starting the handshake")
            pair(host: host, connection: connection)
            return
        }
    }

    /// Runs the handshake on an accepted connection.
    private func pair(host: PairableHost, connection: Int32) {
        defer {
            // Closed under the lock, so a `cancel()` holding it cannot be part-way through a
            // `shutdown` on this descriptor as it goes.
            lock.lock()
            self.connection = -1
            close(connection)
            lock.unlock()

            closeListener()
        }

        // Published before the handshake starts and withdrawn after it ends, so a `cancel()` in
        // between always finds it. One that arrives either side of that window finds -1 and has
        // nothing to do.
        lock.lock()
        self.connection = connection
        let alreadyCancelled = isCancelled
        lock.unlock()

        guard !alreadyCancelled else { return }

        do {
            let pairingData = try host.accept(fileDescriptor: connection) { [weak self] pin in
                Log.network.note("pairing: the device wants a code")
                // The keep-alive's system UI is where the code is read: it is on screen while the
                // user is in Settings, which is the moment they need it.
                PairingKeepAlive.shared.update(subtitle: "Enter \(pin) on this device")

                DispatchQueue.main.async { self?.onPIN(pin) }
            }
            finish(.paired(pairingData))
        } catch {
            // A cancellation arrives here as whatever the handshake made of its socket being shut
            // down underneath it, which is not worth surfacing as a failure the user did not cause.
            if shouldStop { return }
            finish(.failed(reason: error.localizedDescription))
        }
    }

    // MARK: - The listener

    /// Binds a listening socket on an arbitrary free port.
    private func openListener() throws -> UInt16 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw PairingError.socket("socket() \(String(cString: strerror(errno)))")
        }

        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(handle, sa, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bound == 0, listen(handle, 1) == 0 else {
            let reason = String(cString: strerror(errno))
            close(handle)
            throw PairingError.socket("could not listen: \(reason)")
        }

        // The port has to be read back rather than chosen, because it is what gets advertised.
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(handle, sa, &length)
            }
        }
        guard named == 0 else {
            let reason = String(cString: strerror(errno))
            close(handle)
            throw PairingError.socket("could not read the bound port: \(reason)")
        }

        listener = handle
        return UInt16(bigEndian: actual.sin_port)
    }

    /// Closes the listener. Only the wait may call this, or `deinit` once the
    /// wait has returned -- see the note on `listener`.
    private func closeListener() {
        let handle = listener
        listener = -1

        if handle >= 0 { close(handle) }
    }

    // MARK: - Finishing

    /// Whether the wait should give up: cancelled, or overtaken by an outcome
    /// reported from somewhere else. `didNotPublish` is the case in practice.
    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled || isFinished
    }

    /// Why nothing turned up, said as usefully as we can manage.
    ///
    /// A refused Local Network permission is invisible from where this stands:
    /// `publish()` still reports success, `didNotPublish` never fires, and the
    /// advertisement is simply never seen by anyone. The probe in `start()` is
    /// the only warning we get.
    private static func timeoutReason(_ localNetworkLooksUsable: Bool) -> String {
        let timedOut = "no device connected within \(Int(deadline))s"

        guard !localNetworkLooksUsable else { return timedOut }
        return timedOut + " -- and tctiSH may not have Local Network permission"
    }

    /// Delivers the outcome, once, on the main thread.
    private func finish(_ outcome: Outcome) {
        lock.lock()
        let alreadyFinished = isFinished
        isFinished = true
        lock.unlock()

        guard !alreadyFinished else { return }

        let paired: Bool
        if case .paired = outcome { paired = true } else { paired = false }

        DispatchQueue.main.async { [weak self] in
            self?.service?.stop()
            self?.service = nil
            self?.host = nil
            self?.onOutcome(outcome)

            // After the outcome has been handled. `onOutcome` is where the pairing file gets
            // written, and handing the assertion back first would put the one write that matters on
            // the far side of a suspension the app is already a candidate for due to the user being
            // in settings instead of with the app active.
            //
            // Through the singleton rather than `self`, so ending does not depend on this object
            // outliving the hop.
            PairingKeepAlive.shared.end(success: paired)
        }
    }

    /// Something went wrong setting up the socket we advertise.
    ///
    /// A failure to *advertise* is not one of these: `NetService` reports that
    /// through its delegate rather than by throwing, so it arrives as an
    /// `Outcome` instead.
    enum PairingError: LocalizedError {
        case socket(String)

        var errorDescription: String? {
            switch self {
            case .socket(let detail): return detail
            }
        }
    }
}

// MARK: - NetServiceDelegate

extension PairableHostPairing: NetServiceDelegate {

    func netServiceDidPublish(_ sender: NetService) {
        Log.network.note("pairing: advertisement is up as \(sender.name)")
    }

    /// The most likely cause by far is local-network permission being refused,
    /// which arrives here rather than as anything the user is shown.
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        Log.network.note("pairing: could not advertise (error \(code))")

        // The listener is left to the wait, which sees `isFinished` and closes it on its next time
        // round. Closing it from here would be closing another thread's descriptor.
        finish(
            .failed(
                reason: "couldn't advertise on the local network"
                    + " -- check tctiSH's Local Network permission"))
    }
}
