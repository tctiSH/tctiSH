//
//  JitPairingFile.swift
//  Storage for the pairing file StikJIT needs to reach the device.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation

/// The pairing file used to talk to this device over the LocalDevVPN tunnel.
///
/// The location matches StikJIT's recommendation, so a file placed there by any
/// of the usual routes is picked up without further configuration. tctiSH
/// already sets `UIFileSharingEnabled`, so it can be dropped in over AFC or
/// Finder without an in-app importer.
enum JitPairingFile {

    /// `Documents/StikJIT/pairingFile.plist`.
    static var url: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask)[0]
        return
            documents
            .appendingPathComponent("StikJIT", isDirectory: true)
            .appendingPathComponent("pairingFile.plist")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Reads the pairing file, or nil if it isn't there or can't be read.
    static func read() -> Data? {
        try? Data(contentsOf: url)
    }

    /// How an interactive import turned out.
    ///
    /// Cancelling and failing are different events and want different answers:
    /// one is the user deciding, and deserves no comment, while the other is
    /// something going wrong that they'd want telling about.
    enum ImportResult {
        case imported
        case cancelled
        case failed(reason: String)
    }

    /// Asks the user for a pairing file and stores it.
    ///
    /// Blocks until the user picks or cancels, so call it off the main thread.
    @discardableResult
    static func importInteractively() -> ImportResult {
        let picked = PairingFilePicker.popUpModalDialog()
        guard let source = picked.first else {
            Log.fs.note("pairing: import cancelled")
            return .cancelled
        }

        // Files chosen through the picker live outside our container, so they need the security
        // scope held open for the length of the copy.
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try install(from: source)
        } catch {
            Log.fs.note("pairing: could not import (\(error.localizedDescription))")
            return .failed(reason: error.localizedDescription)
        }

        Log.fs.note("pairing: imported \(source.lastPathComponent)")
        return .imported
    }

    /// Stores a pairing file this device produced for us.
    ///
    /// The bytes have already been proved by the handshake that produced them,
    /// so there is nothing further to verify.
    static func store(_ pairingData: Data) throws {
        try install(contents: pairingData)
        Log.fs.note("pairing: stored \(pairingData.count) bytes")
    }

    /// Copies `source` into place, replacing any existing pairing file.
    private static func install(from source: URL) throws {
        try install(contents: try Data(contentsOf: source))
    }

    /// Writes `contents` into place, replacing any existing pairing file.
    ///
    /// The write is atomic so an interrupted import can't leave a half-written
    /// pairing file behind, and a failed one can't destroy a working file.
    private static func install(contents: Data) throws {
        let destination = url

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        try contents.write(to: destination, options: .atomic)
    }
}
