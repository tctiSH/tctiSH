//
//  DefaultCommand.swift
//  Sends the guest the command new terminals start in place of the shell.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// Tells the guest the command set in Settings > Terminals, such as xonsh.
/// `tctish-agent` writes it to a file that each login on the app's consoles
/// reads from; see `zz_default_command.sh` in the guest.
///
/// Sent when Linux comes up (a boot, a resume, a reset), when the machine is
/// back after the app was away, and when the setting changes. A login before
/// the first of these asks `ConfigServer` instead.
///
/// Use it from the main thread.
final class DefaultCommand {

    static let shared = DefaultCommand()

    /// How long typing in Settings pauses before the command is sent, so that
    /// it isn't sent a letter at a time.
    private static let typingPause: TimeInterval = 0.5

    private var pendingSend: DispatchWorkItem?

    private init() {}

    /// The command, on one line, as a login reads it; empty for the shell.
    static var current: String {
        AppSetting.defaultCommand.string
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Sends the command whenever Linux comes up or the machine is back.
    /// Settings calls `settingChanged` when the setting changes.
    func start() {
        let center = NotificationCenter.default
        for name in [GuestAgent.linuxDidComeUp, AppDelegate.machineIsBack] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.send()
            }
        }
    }

    /// Sends the command once typing pauses.
    func settingChanged() {
        pendingSend?.cancel()
        let send = DispatchWorkItem { [weak self] in self?.send() }
        pendingSend = send
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingPause, execute: send)
    }

    /// Sends the command, if Linux is up to take it. Otherwise it goes when
    /// Linux comes up or the machine is back.
    private func send() {
        pendingSend?.cancel()
        pendingSend = nil

        // Not while the machine is stopped for a save or parked: the request would wait in the
        // socket. The machine's return sends it again.
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        guard GuestAgent.shared.isUp, appDelegate?.machineIsAway != true else { return }

        // In base64, as the agent takes no argument with a space.
        let command = Self.current
        let encoded = command.isEmpty ? "-" : Data(command.utf8).base64EncodedString()

        GuestAgent.shared.request("default-command", encoded) { answer in
            if case .failed(let why) = answer {
                Log.qemu.warn("default command: not sent: \(why)")
            }
        }
    }
}
