//
//  JITHelperClient.swift
//  Host side of the conversation with the JIT helper extension.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation

/// Sends operations to the JIT helper and reports what came back.
///
/// Deliberately thin as `JITHelperLauncher` owns starting the extension and the
/// promise that the completion runs exactly once; `JITHelper` owns the vocab.
/// This puts the two together and makes sure every exchange leaves a trace in
/// the log.
enum JITHelperClient {

    /// How long each operation is given before the host stops waiting.
    enum Timeout {

        /// `enable` blocks until QEMU traps, and QEMU cannot trap until the
        /// host has booted it, so this bounds the whole of enablement, not just
        /// the attach the host is actually waiting for.
        static let enable: TimeInterval = 60
    }

    // MARK: - Operations



    /// Attaches the debugger and answers QEMU's blessing trap.
    ///
    /// Returns when enablement is *over*, which is long after the point the host
    /// cares about: the attach lands early, QEMU is booted once it has, and this
    /// only comes back once the region has been blessed. Callers wait on the
    /// attach -- see `jit_debugger_tracing()` -- and treat this completion as
    /// the after-the-fact report it is.
    static func enable(pairingData: Data?,
                       targetPID: pid_t,
                       completion: @escaping (JITHelper.Reply?) -> Void) {
        send(JITHelper.Request(operation: .enable,
                               pairingData: pairingData,
                               targetPID: targetPID),
             timeout: Timeout.enable,
             completion: completion)
    }

    // MARK: - Plumbing

    static func send(_ request: JITHelper.Request,
                     timeout: TimeInterval,
                     completion: @escaping (JITHelper.Reply?) -> Void) {
        let operation = request.operation.rawValue
        let started = Date()

        func elapsed() -> String {
            String(format: "%.1fs", Date().timeIntervalSince(started))
        }

        Log.jit.note("host: \(operation)...")

        JITHelperLauncher.launch(withPayload: request.userInfo,
                                 timeout: timeout) { helperPid, replyItems, error in
            if let error {
                Log.jit.note("host: \(operation) failed after \(elapsed()) "
                            + "(\(error.localizedDescription))")
                completion(nil)
                return
            }

            guard let reply = JITHelper.Reply(replyItems: replyItems) else {
                Log.jit.note("host: \(operation) replied with something unreadable "
                            + "after \(elapsed())")
                completion(nil)
                return
            }

            Log.jit.note("host: \(operation) \(reply.outcome.rawValue) after \(elapsed()) "
                        + "(helper pid \(helperPid)): \(reply.detail)")

            // The helper logs these itself, but a helper the system killed takes
            // its buffered log with it, so what made it back here is what we can
            // rely on having.
            for line in reply.report {
                Log.jit.note("host:   \(line)")
            }

            completion(reply)
        }
    }
}
