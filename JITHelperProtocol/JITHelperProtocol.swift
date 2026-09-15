//
//  JITHelperProtocol.swift
//  Vocabulary shared between tctiSH and its out-of-process JIT helper.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation

/// The request/response vocabulary spoken across the extension boundary.
///
/// This file is compiled into *both* targets so we have one definition shared
/// by both protocol paricipants.
///
/// Everything crossing the boundary travels as an `NSExtensionItem.userInfo`
/// dictionary, so everything here has to be property-list representable.
enum JITHelper {

    /// What the host is asking the helper to do.
    enum Operation: String {

        /// Attaches the debugger and answers QEMU's blessing traps.
        case enable
    }

    /// Whether the helper did the thing.
    enum Outcome: String {
        case succeeded
        case failed
    }

    // MARK: - Request

    /// What the host sends.
    struct Request {
        var operation: Operation

        /// Contents of the pairing file, not its path: the helper has its own
        /// container, so nothing the host can name is reachable from there.
        var pairingData: Data?

        /// The process the debugger should attach to: the host, always.
        var targetPID: pid_t?

        init(operation: Operation, pairingData: Data? = nil, targetPID: pid_t? = nil) {
            self.operation = operation
            self.pairingData = pairingData
            self.targetPID = targetPID
        }

        var userInfo: [String: Any] {
            var info: [String: Any] = [Key.operation: operation.rawValue]
            if let pairingData { info[Key.pairingData] = pairingData }
            if let targetPID { info[Key.targetPID] = Int(targetPID) }
            return info
        }

        /// Recovers a request, or nil if this isn't one we understand.
        init?(userInfo: [AnyHashable: Any]?) {
            guard let raw = userInfo?[Key.operation] as? String,
                let operation = Operation(rawValue: raw)
            else {
                return nil
            }

            self.operation = operation
            self.pairingData = userInfo?[Key.pairingData] as? Data
            self.targetPID = (userInfo?[Key.targetPID] as? Int).map(pid_t.init)
        }

        private enum Key {
            static let operation = "operation"
            static let pairingData = "pairingData"
            static let targetPID = "targetPID"
        }
    }

    // MARK: - Reply

    /// What the helper sends back.
    struct Reply {
        var outcome: Outcome = .failed

        /// One line saying what happened, for the host's log and for the user.
        var detail: String = ""

        /// The helper's full transcript.
        var report: [String] = []

        /// The helper's own reading of TXM presence.
        var txmPresent: Bool?

        /// Whether the developer disk image was already mounted. `status` only.
        var ddiMounted: Bool?

        /// Wall-clock time the operation took.
        var elapsed: TimeInterval = 0

        init() {}

        var userInfo: [String: Any] {
            var info: [String: Any] = [
                Key.outcome: outcome.rawValue,
                Key.detail: detail,
                Key.report: report,
                Key.elapsed: elapsed,
            ]
            if let txmPresent { info[Key.txmPresent] = txmPresent }
            if let ddiMounted { info[Key.ddiMounted] = ddiMounted }
            return info
        }

        /// Recovers a reply from what came back over the extension request.
        init?(replyItems: [Any]?) {
            guard let info = (replyItems?.first as? NSExtensionItem)?.userInfo,
                let raw = info[Key.outcome] as? String,
                let outcome = Outcome(rawValue: raw)
            else {
                return nil
            }

            self.outcome = outcome
            self.detail = info[Key.detail] as? String ?? ""
            self.report = info[Key.report] as? [String] ?? []
            self.txmPresent = info[Key.txmPresent] as? Bool
            self.ddiMounted = info[Key.ddiMounted] as? Bool
            self.elapsed = info[Key.elapsed] as? TimeInterval ?? 0
        }

        private enum Key {
            static let outcome = "outcome"
            static let detail = "detail"
            static let report = "report"
            static let txmPresent = "txmPresent"
            static let ddiMounted = "ddiMounted"
            static let elapsed = "elapsed"
        }
    }
}
