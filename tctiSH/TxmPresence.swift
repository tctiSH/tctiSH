//
//  TxmPresence.swift
//  Whether this device has a Trusted eXecution Monitor.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import StikJIT

/// Whether this device has a Trusted eXecution Monitor.
enum TxmPresence {

    /// TXM is enforcing code signing.
    case present

    /// No TXM; the kernel enforces code signing itself.
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
