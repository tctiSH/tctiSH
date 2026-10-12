//
//  TerminalTransport.swift
//  The transports that carry a terminal's bytes to and from Linux.
//
//  Copyright © 2022 Kate Temkin <k@ktemkin.com>.
//  Copyright © 2026 Ara Adkins.
//

import Combine
import Foundation
import SwiftSH
import SwiftTerm

/// Carries a terminal's bytes to and from Linux.
///
/// Transports are separate from terminal views because they live for different
/// lengths of time: a TTY's view is freed when the TTY is closed, but the SSH
/// session behind `hvc0` is how the app tells whether Linux is up at all, so it
/// has to outlive the view.
protocol TerminalTransport: AnyObject {

    /// The view the transport delivers output to. Weak, because the view holds
    /// the transport.
    var terminal: TctiTermView? { get set }

    /// Sends what was typed into the terminal to the far end.
    func send(_ data: ArraySlice<UInt8>)

    /// Tells the far end the terminal's size, in columns and rows.
    func resize(cols: Int, rows: Int)
}

// MARK: - SSH

/// The SSH session to the guest, shown in the `hvc0` TTY.
///
/// There is only one, and it runs whether or not the `hvc0` TTY is open,
/// because the app depends on it: the VM is saved only once the session has
/// connected, and the session is rebuilt when the app resumes. While `hvc0` is
/// closed, the session's output is discarded.
final class SSHTransport: TerminalTransport {

    static let shared = SSHTransport()

    /// How often to try connecting, until a connection succeeds.
    private static let pollingInterval: TimeInterval = 1.5

    /// Set to true to enable SSH logging from the first attempt.
    private static let loggingEnabled = false

    /// How many failed attempts in a row are logged quietly, as a slow boot,
    /// before failures are logged as warnings and libssh2 tracing is turned on.
    private static let quietFailures = 3

    /// Posted once the SSH session is up and there's a shell to type at.
    static let didConnect = Notification.Name("io.ara.tctish.terminalDidConnect")

    /// Posted when `forceReconnect()` drops the session and starts connecting
    /// again.
    ///
    /// Reconnecting takes a few seconds and the terminal does not respond
    /// meanwhile, which looks exactly like a hang unless the UI says otherwise.
    static let willReconnect = Notification.Name("io.ara.tctish.terminalWillReconnect")

    weak var terminal: TctiTermView? {
        didSet {
            guard let terminal, terminal !== oldValue, connected else { return }

            // A new view has been attached to a session that is already connected, as when `hvc0`
            // is closed and opened again. Tell the far end the new view's size.
            let t = terminal.getTerminal()
            resize(cols: t.cols, rows: t.rows)
        }
    }

    private var shell: SSHShell?

    /// Whether an attempt is already in flight.
    ///
    /// The poll fires every `pollingInterval` until `connected`, which is set
    /// only once an attempt *succeeds*. Without this flag, a guest whose sshd
    /// takes longer than that to come up gets a second `connect()` stacked on
    /// the first, and a third on that. libssh2 is stateful and not re-entrant,
    /// and the result is an authentication failure that looks like a wrong
    /// password.
    private var connecting = false

    /// How many attempts have failed since the last success.
    ///
    /// The first few failures are expected, because the guest isn't listening
    /// yet, so they're logged quietly. After that something is actually wrong,
    /// and libssh2's tracing is turned on, rather than waiting for someone to
    /// think of rebuilding with it enabled.
    private var failedAttempts = 0

    /// Whether the SSH session is up.
    var connected = false {
        didSet {
            guard connected, !oldValue else { return }
            NotificationCenter.default.post(name: Self.didConnect, object: self)
        }
    }

    /// The timer that polls for a connection until one succeeds. Each call to
    /// `start()` replaces it.
    private var timer: Publishers.Autoconnect<Timer.TimerPublisher>?
    private var subscription: AnyCancellable?

    private init() {
        makeShell()
    }

    /// Builds a fresh SSH session.
    ///
    /// It always makes a new session. A session that failed part way through
    /// authenticating can't be trusted to start again cleanly, so retries begin
    /// from scratch rather than reusing whatever state the last attempt left
    /// behind.
    private func makeShell() {
        shell = try? SSHShell(
            sshLibrary: Libssh2.self,
            host: "localhost",
            port: 10022,
            environment: [],
            terminal: "xterm-256color")

        shell?.log.enabled = Self.loggingEnabled || failedAttempts >= Self.quietFailures
    }

    /// Starts trying to connect to the VM every `pollingInterval`, until a
    /// connection succeeds.
    func start() {
        // Cancel any poll already running, so that this one replaces it.
        subscription?.cancel()
        timer?.upstream.connect().cancel()

        timer = Timer.publish(every: Self.pollingInterval, on: .main, in: .common).autoconnect()
        subscription = timer?.sink { [unowned self] _ in
            if connected {
                timer?.upstream.connect().cancel()
            } else {
                connect()
            }
        }
    }

    /// Forces the SSH session to reconnect.
    func forceReconnect() {
        // Mark the session as not connected. This matters for two reasons: it lets `didConnect`
        // fire again once the new session connects, and it stops the poll started below from
        // cancelling itself on its first tick.
        connected = false
        connecting = false
        failedAttempts = 0
        NotificationCenter.default.post(name: Self.willReconnect, object: self)

        // Replace the SSH session with a new one...
        makeShell()

        // ... start a new line, so that the cursor is in a valid drawing position again...
        terminal?.feed(text: "\r\n")

        // ... and poll until it connects, rather than making a single attempt. A reconnect that
        // made one attempt, and failed quietly, used to leave a dead terminal that nothing would
        // try to reconnect.
        start()
    }

    private func received(data: Data?, error: Data?) {
        guard let data else { return }
        terminal?.receive(Array(data)[...])
    }

    private func connect() {
        // Never start an attempt while another is still in flight (see `connecting`). Failures on
        // the first few tries are expected, because the guest usually isn't listening yet, and are
        // logged quietly below.
        guard !connecting else {
            Log.network.note("ssh: still trying the last connection; not starting another")
            return
        }

        guard let s = shell else { return }
        connecting = true
        terminal?.setUpTheming()

        s.withCallback { [unowned self] (data: Data?, error: Data?) in
            received(data: data, error: error)
        }
        .connect()
        .authenticate(.byPassword(username: "root", password: "toor"))
        .open { [unowned self] (error) in
            connecting = false

            if let error {
                failedAttempts += 1

                let detail = "attempt \(failedAttempts) failed: \(error)"
                if failedAttempts < Self.quietFailures {
                    // Expected while the guest is still coming up.
                    Log.network.note("ssh: \(detail)")
                } else {
                    Log.network.warn("ssh: \(detail)")
                    if failedAttempts == Self.quietFailures {
                        Log.network.warn("ssh: turning on libssh2 tracing for the next attempt")
                    }
                }

                // Replace the failed session, which can't be reused, so that the next attempt
                // starts from a clean one.
                makeShell()
                return
            }

            if failedAttempts > 0 {
                Log.network.note("ssh: connected after \(failedAttempts) failed attempts")
            }
            failedAttempts = 0

            // The guest has booted, so clear `attempting_boot`.
            connected = true
            UserDefaults.standard.set(false, forKey: "attempting_boot")

            // If `hvc0` is open, tell the SSH server its size, so that the server sizes its PTY to
            // match, then redraw the whole terminal for the new connection.
            if let t = terminal?.getTerminal() {
                _ = s.setTerminalSize(width: UInt(t.cols), height: UInt(t.rows))
                t.updateFullScreen()
            }
        }
    }

    func send(_ data: ArraySlice<UInt8>) {
        shell?.write(Data(data)) { error in
            if let error {
                Log.network.warn("ssh: couldn't send: \(error)")
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        _ = shell?.setTerminalSize(width: UInt(cols), height: UInt(rows))
    }
}

// MARK: - Echo

/// A transport with nothing behind it, which echoes back whatever is typed.
///
/// It stands in for a TTY that isn't connected to Linux yet, so that the TTY
/// still behaves like a terminal: typed text appears, Return starts a new line,
/// Backspace erases the character before the cursor, and Ctrl-G rings the bell.
final class EchoTransport: TerminalTransport {

    weak var terminal: TctiTermView?

    func send(_ data: ArraySlice<UInt8>) {
        var echoed: [UInt8] = []
        for byte in data {
            switch byte {
            case 0x0d: echoed += [0x0d, 0x0a]
            case 0x7f, 0x08: echoed += [0x08, 0x20, 0x08]
            default: echoed.append(byte)
            }
        }
        terminal?.receive(echoed[...])
    }

    func resize(cols: Int, rows: Int) {}
}
