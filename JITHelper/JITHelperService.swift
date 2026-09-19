//
//  JITHelperService.swift
//  Out-of-process helper used to enable JIT for the host app.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import os
import StikJIT

/// Matches the host's `Log.jit`, so one Console filter catches both processes.
///
/// Not the host's `Log` type itself: that lives in the app target and this is a
/// separate binary. The subsystem string is the contract between the two.
///
/// Public because the unified log otherwise redacts every interpolated value to
/// `<private>`, which makes the messages useless for diagnosis.
private let jitLogger = Logger(subsystem: "io.ara.tctish.jit", category: "jit")
private func jitNote(_ message: String) {
    jitLogger.notice("\(message, privacy: .public)")
}

/// Handles requests from tctiSH.
///
/// A process cannot attach a debugger to itself: the `brk` QEMU uses to request
/// its JIT region stops every thread, including whichever one is driving the
/// debug connection. StikJIT therefore has to run somewhere other than the app,
/// and an app extension is all we have access to that can do this.
///
class JITHelperService: NSObject, NSExtensionRequestHandling {

    /// StikJIT's APIs are synchronous and blocking, and the guide requires them
    /// to run on a single serial queue rather than being spread across tasks.
    private let work = DispatchQueue(label: "io.ara.tctiSH.JITHelper.work")

    func beginRequest(with context: NSExtensionContext) {
        let request = JITHelper.Request(
            userInfo: (context.inputItems.first as? NSExtensionItem)?.userInfo)

        work.async {
            var reply = JITHelper.Reply()
            var report: [String] = []

            func note(_ line: String) {
                jitNote("helper: \(line)")
                report.append(line)
            }

            // A local IORegistry read: no tunnel, no pairing file, no cost. The host works this out
            // independently and compares, so a drift between the two gates shows up in the log
            // instead of as a hang.
            reply.txmPresent = StikJIT.isTXMPresent

            let started = Date()
            note(
                "pid \(getpid()), \(Self.availableMemory()) available, "
                    + "TXM \(Self.describe(reply.txmPresent))")

            if let request {
                note("operation: \(request.operation.rawValue)")
                self.perform(request, into: &reply, note: note)
            } else {
                reply.detail = "no operation requested"
                note(reply.detail)
            }

            reply.elapsed = Date().timeIntervalSince(started)
            reply.report = report

            note(
                "\(reply.outcome.rawValue) in \(Self.describe(reply.elapsed)), "
                    + "\(Self.availableMemory()) available")

            self.complete(context, reply: reply)
        }
    }

    private func perform(
        _ request: JITHelper.Request,
        into reply: inout JITHelper.Reply,
        note: @escaping (String) -> Void
    ) {
        switch request.operation {
        case .enable:
            enable(
                pairingData: request.pairingData,
                targetPID: request.targetPID,
                into: &reply,
                note: note)
        }
    }

    // MARK: - Operations

    /// Attaches the debugger and answers QEMU's blessing traps.
    ///
    /// Blocks for longer than it seems: the universal script stays attached,
    /// serving `brk #0xf00d` calls until QEMU asks it to detach once every code
    /// region is prepared. The host that to issue this _before_ it starts QEMU
    /// and then wait for the attach to land.
    ///
    /// The host **must not** issue this unless it is going to boot QEMU under
    /// TCG expecting to be able to JIT. If this is not done, the script will
    /// wait forever and hang the app.
    private func enable(
        pairingData: Data?,
        targetPID: pid_t?,
        into reply: inout JITHelper.Reply,
        note: @escaping (String) -> Void
    ) {
        guard let pairingData else {
            reply.detail = "no pairing file, so JIT cannot be enabled"
            note(reply.detail)
            return
        }

        guard let targetPID else {
            reply.detail = "no target pid given"
            note(reply.detail)
            return
        }

        do {
            try withPairingFile(pairingData) { pairingFile in
                // Ask before attaching. `enableJIT` would happily prepare the device for us, but
                // preparing means downloading and mounting a developer disk image: minutes of work,
                // finishing long after the host stopped waiting and booted without JIT.
                let mounted = try StikJIT.isDDIMounted(pairingFile: pairingFile)
                reply.ddiMounted = mounted

                guard mounted else {
                    reply.detail = "developer disk image is not mounted, so not attaching"
                    return
                }

                // `enableJIT(ddiPaths:)` would run `prepareDevice`, which opens a second tunnel
                // purely to ask the same question again.
                try StikJIT.enableJITOnPreparedDevice(
                    targetPID: targetPID,
                    pairingFile: pairingFile,
                    script: .universal,
                    forceScript: false,
                    progress: { note("  \($0)") })

                reply.outcome = .succeeded
                reply.detail = "JIT enabled"
            }
        } catch {
            reply.detail = "could not enable JIT: \(error.localizedDescription)"
        }

        note(reply.detail)
    }

    // MARK: - Plumbing

    /// Stages the pairing data as a file for the length of `body`.
    private func withPairingFile<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        let pairingFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pairing-\(getpid()).plist")

        try data.write(to: pairingFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: pairingFile) }

        return try body(pairingFile)
    }

    private func complete(_ context: NSExtensionContext, reply: JITHelper.Reply) {
        let item = NSExtensionItem()
        item.userInfo = reply.userInfo
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    // MARK: - Reporting

    /// How much memory this process can still allocate before being jetsammed.
    private static func availableMemory() -> String {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? "\(bytes / (1024 * 1024))MB" : "unknown"
    }

    private static func describe(_ present: Bool?) -> String {
        present.map { $0 ? "present" : "absent" } ?? "unknown"
    }

    private static func describe(_ elapsed: TimeInterval) -> String {
        String(format: "%.1fs", elapsed)
    }

}
