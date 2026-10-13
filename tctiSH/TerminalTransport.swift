//
//  TerminalTransport.swift
//  The transports that carry a terminal's bytes to and from Linux.
//
//  Copyright © 2022 Kate Temkin <k@ktemkin.com>.
//  Copyright © 2026 Ara Adkins.
//

import SwiftTerm
import UIKit

/// Carries a terminal's bytes to and from Linux.
///
/// Transports are separate from terminal views because they live for different
/// lengths of time: a TTY's view is freed when the TTY is closed, but what runs
/// on `hvc0` carries on regardless, and is there when the TTY is opened again.
protocol TerminalTransport: AnyObject {

    /// The view the transport delivers output to. Weak, because the view holds
    /// the transport.
    var terminal: TctiTermView? { get set }

    /// Sends what was typed into the terminal to the far end.
    func send(_ data: ArraySlice<UInt8>)

    /// Tells the far end the terminal's size, in columns and rows.
    func resize(cols: Int, rows: Int)
}

// MARK: - Console

/// A virtio console in the guest, shown in the TTY of the same name.
final class ConsoleTransport: TerminalTransport {

    static let shared = ConsoleTransport(device: "hvc0")

    /// The console's name in Linux, and its device's ID in QEMU.
    let device: String

    weak var terminal: TctiTermView? {
        didSet {
            // A new view has been attached, as when `hvc0` is closed and opened again. Tell the
            // guest its size, and have what is running draw itself into the new, empty view:
            // nothing the guest wrote while the console was closed was kept.
            guard let terminal, terminal !== oldValue else { return }
            let t = terminal.getTerminal()
            resize(cols: t.cols, rows: t.rows, redrawing: true)
        }
    }

    private let socket: ChardevSocket

    private init(device: String) {
        self.device = device
        socket = ChardevSocket(path: QEMUInterface.consoleSocketPath(device), name: device)
        socket.onReceive = { [unowned self] bytes in terminal?.receive(bytes) }

        // Before Linux is up, a size has nowhere to go: the monitor is still busy with the launch.
        NotificationCenter.default.addObserver(
            forName: GuestAgent.linuxDidComeUp, object: nil, queue: .main
        ) { [unowned self] _ in
            guard let t = terminal?.getTerminal() else { return }
            resize(cols: t.cols, rows: t.rows, redrawing: true)
        }
    }

    /// Connects to the console, and keeps it connected.
    func start() {
        socket.start()
    }

    func send(_ data: ArraySlice<UInt8>) {
        socket.send(data)
    }

    func resize(cols: Int, rows: Int) {
        resize(cols: cols, rows: rows, redrawing: false)
    }

    private func resize(cols: Int, rows: Int, redrawing: Bool) {
        guard GuestAgent.shared.isUp, cols > 0, rows > 0 else { return }
        (UIApplication.shared.delegate as? AppDelegate)?.qemu?.resizeConsole(
            device, cols: cols, rows: rows, redrawing: redrawing)
    }
}

// MARK: - Character devices

/// One of QEMU's character devices, shown as it is: the serial port in Kernel
/// Log, or the user's monitor in VM Management. Unlike a virtio console,
/// neither has a size to be told, so a resize goes nowhere.
final class ChardevTransport: TerminalTransport {

    /// `ttyS0`, the machine's serial port: the kernel's log from the first
    /// instruction, and a login under it for when `hvc0` can't be reached.
    ///
    /// What it sends is read from the file QEMU keeps of it, which has
    /// everything since QEMU started, connected or not; the socket is for
    /// typing, and what arrives on it is thrown away.
    static let kernelLog = ChardevTransport(name: "ttyS0", logged: true)

    /// QEMU's monitor, a second one beside the app's, so that what is typed
    /// here never lands in the middle of a command the app is running. What is
    /// typed goes through a `MonitorGate`, which asks before risky commands.
    static let vmManagement = ChardevTransport(name: "hmp", logged: false)

    /// Where QEMU listens for the app's connection.
    let socketPath: String

    /// Where QEMU keeps what the device sends, if it does.
    let logPath: String?

    /// Asks whether to submit a monitor command that `MonitorGuard` flags, and
    /// calls back with the answer. Set for VM Management; it must call back.
    var confirm: ((MonitorGuard.Risk, @escaping (Bool) -> Void) -> Void)? {
        get { gate?.confirm }
        set { gate?.confirm = newValue }
    }

    /// Called with the terminal's size whenever it changes.
    var onResize: ((Int, Int) -> Void)?

    weak var terminal: TctiTermView? {
        didSet {
            guard let terminal, !notes.isEmpty else { return }
            notes.forEach(terminal.feed(text:))
            notes.removeAll()
        }
    }

    private let socket: ChardevSocket
    private let tail: FileTail?
    private var gate: MonitorGate?

    /// Notes waiting for a terminal to show them in.
    private var notes: [String] = []

    private init(name: String, logged: Bool) {
        socketPath = QEMUInterface.socketPath(name)
        logPath = logged ? QEMUInterface.logPath(name) : nil
        socket = ChardevSocket(path: socketPath, name: name, discardingOutput: logged)
        tail = logPath.map { FileTail(path: $0, name: name) }

        tail?.onReceive = { [unowned self] bytes in terminal?.receive(bytes) }
        if !logged {
            let gate = MonitorGate(screen: { [unowned self] in terminal?.getTerminal() }) {
                [unowned self] bytes in socket.send(bytes)
            }
            socket.onReceive = { [unowned self, unowned gate] bytes in
                terminal?.receive(bytes)
                gate.received()
            }
            socket.onConnect = { [unowned gate] in gate.connected() }
            self.gate = gate
        }
    }

    /// Connects to the device, and keeps it connected.
    func start() {
        socket.start()
    }

    /// Starts following the file QEMU keeps of what the device sends, once QEMU
    /// has been started with the old one removed.
    func followLog() {
        tail?.start()
    }

    /// Shows a line from the app, rather than from the far end, dimmed to tell
    /// them apart.
    func note(_ text: String) {
        let line = "\u{1b}[2m\(text)\u{1b}[0m\r\n"
        guard let terminal else {
            notes.append(line)
            return
        }
        terminal.feed(text: line)
    }

    func send(_ data: ArraySlice<UInt8>) {
        guard let gate else {
            socket.send(data)
            return
        }
        gate.send(data)
    }

    func resize(cols: Int, rows: Int) {
        onResize?(cols, rows)
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
