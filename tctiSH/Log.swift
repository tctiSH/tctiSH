//
//  Log.swift
//  Logging, split by subsystem.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import os

/// One area of the app's logging.
///
/// Each area gets its own subsystem, so Console can be pointed at a single
/// concern, while filtering on the root still catches the lot.
///
/// Every line also goes to `LogFile`, so it can be read back on the device.
///
/// Everything is logged `.public`. The unified log redacts interpolated values
/// by default, which makes messages useless for diagnosis, and nothing logged
/// here is sensitive. In particular the pairing file's *contents* never pass
/// through it, only its path.
struct Log {

    /// Deciding whether and how JIT can be enabled, and talking to the helper.
    static let jit = Log("jit")

    /// Starting and running the VM.
    static let qemu = Log("qemu")

    /// Anything that goes over a wire: the tunnel, the developer disk image,
    /// SSH, the configuration server.
    static let network = Log("network")

    /// Files and the places they live.
    static let fs = Log("fs")

    /// The app itself -- lifecycle, screens, what the user is being shown.
    static let ui = Log("ui")

    private let logger: Logger
    private let area: String

    private init(_ area: String) {
        self.area = area
        logger = Logger(subsystem: "io.ara.tctish.\(area)", category: area)
    }

    /// Something happened that's worth being able to read back later.
    func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        LogFile.append(area: area, level: nil, message: message)
    }

    /// Something is off, but we carried on.
    func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        LogFile.append(area: area, level: "warning", message: message)
    }

    /// Something failed.
    func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LogFile.append(area: area, level: "error", message: message)
    }
}
