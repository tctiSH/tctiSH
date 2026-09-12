//
//  TxmPresence.swift
//  Whether this device has a Trusted eXecution Monitor.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import StikJIT

/// Whether this device has a Trusted eXecution Monitor.
///
/// This asks StikJIT rather than working it out. The host decides whether QEMU
/// raises its blessing trap and StikJIT decides whether anything is listening
/// for one, so a disagreement between them doesn't produce an error, it
/// produces a hang. Sharing one implementation is the only way to be sure they
/// can't drift.
enum TxmPresence {

    /// TXM is enforcing: the process cannot make its own mappings executable,
    /// and a debugger has to bless each JIT region.
    case present

    /// No TXM: believing itself debugged is enough for the process to JIT.
    case absent

    /// The IORegistry didn't answer. Not a synonym for `absent`.
    case unknown

    static var current: TxmPresence {
        guard let present = StikJIT.isTXMPresent else { return .unknown }
        return present ? .present : .absent
    }

    var isPresent: Bool? {
        switch self {
        case .present: return true
        case .absent: return false
        case .unknown: return nil
        }
    }

    var description: String {
        switch self {
        case .present: return "present"
        case .absent: return "absent"
        case .unknown: return "unknown"
        }
    }
}
