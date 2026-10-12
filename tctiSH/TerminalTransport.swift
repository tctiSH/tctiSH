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
