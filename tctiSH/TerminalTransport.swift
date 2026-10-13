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
/// on its console carries on regardless, and is there when a TTY shows the
/// console again.
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

/// A virtio console in the guest, shown in the user TTY of the same name.
///
/// It is connected only while a TTY shows it. What the guest writes to a
/// console no TTY shows would be thrown away regardless, and QEMU throws it
/// away more cheaply than the app can.
final class ConsoleTransport: TerminalTransport {

    /// Every console, `hvc0` to `hvc11`, by number.
    static let consoles = (0..<Int(TCTISH_CONSOLE_COUNT)).map {
        ConsoleTransport(device: "hvc\($0)")
    }

    /// The console's name in Linux, and its device's ID in QEMU.
    let device: String

    weak var terminal: TctiTermView? {
        didSet {
            guard terminal !== oldValue else { return }
            guard terminal != nil else {
                socket.stop()
                return
            }

            // A view has been attached, as when the TTY is opened, or the app is launched with it
            // open. Tell the guest its size, and have what is running draw itself into the new,
            // empty view: nothing the guest wrote while no TTY showed the console was kept. The
            // socket connects once QEMU has started, rather than retrying until then, which
            // Settings First can make a long wait.
            if AppDelegate.qemuStarted {
                socket.start()
            }
            redraw()
        }
    }

    private let socket: ChardevSocket

    private init(device: String) {
        self.device = device
        socket = ChardevSocket(path: QEMUInterface.consoleSocketPath(device), name: device)
        socket.onReceive = { [unowned self] bytes in terminal?.receive(bytes) }

        NotificationCenter.default.addObserver(
            forName: AppDelegate.qemuDidStart, object: nil, queue: .main
        ) { [unowned self] _ in
            if terminal != nil {
                socket.start()
            }
        }

        // Before Linux is up, a size has nowhere to go: the monitor is still busy with the launch.
        // Once it is, a run-loop turn later, so that the guest clock's time reaches the agent
        // first: each console's `shown` takes the agent a moment.
        NotificationCenter.default.addObserver(
            forName: GuestAgent.linuxDidComeUp, object: nil, queue: .main
        ) { [unowned self] _ in
            DispatchQueue.main.async { [unowned self] in redraw() }
        }
    }

    func send(_ data: ArraySlice<UInt8>) {
        socket.send(data)
    }

    func resize(cols: Int, rows: Int) {
        resize(cols: cols, rows: rows, redrawing: false)
    }

    /// Has what runs on the console draw itself again, if a TTY shows it.
    ///
    /// Also tells the guest agent that a TTY shows the console, which starts
    /// the console's login if it is waiting for a TTY: see `tctish-login`.
    func redraw() {
        guard let t = terminal?.getTerminal() else { return }
        if GuestAgent.shared.isUp {
            GuestAgent.shared.request("shown", device) { [device] answer in
                guard case .failed(let reason) = answer else { return }
                Log.ui.warn("\(device): couldn't say it is shown: \(reason)")
            }
        }
        resize(cols: t.cols, rows: t.rows, redrawing: true)
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
