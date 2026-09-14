//
//  DdiPreparation.swift
//  Fetching and mounting the developer disk image, in-process.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import StikJIT

/// Gets the developer disk image onto the device.
///
/// This runs in the app so the download can report bytes as they arrive and the
/// mount reports its own fraction. The helper only handles the debugger attach.
enum DdiPreparation {

    /// Where the image is cached: the app's own container, now that the app is
    /// what fetches and mounts it.
    static var paths: DDIPaths {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return DDIPaths.default(in: library.appendingPathComponent("StikJIT"))
    }

    /// Where the pieces of a developer disk image come from.
    ///
    /// Duplicated from StikJIT's `DDIDownloadCatalog`, which is internal to the
    /// framework and so can't be borrowed. If StikJIT ever moves these, this
    /// has to follow; a stale URL shows up as a download that 404s.
    private static let catalogue = URL(
        string: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main"
            + "/PersonalizedImages/Xcode_iOS_DDI_Personalized")!

    private static func downloads(for paths: DDIPaths) -> [(name: String, destination: String)] {
        [
            ("BuildManifest.plist", paths.manifestPath),
            ("Image.dmg", paths.imagePath),
            ("Image.dmg.trustcache", paths.trustcachePath),
        ]
    }

    enum Outcome {
        case ready
        case failed(String)
    }

    /// How far along, and what it's doing.
    typealias Progress = (_ message: String, _ fraction: Double?) -> Void

    /// Gets the device ready, reporting as it goes.
    ///
    /// Blocking, so call it off the main thread. Progress arrives on whatever
    /// thread the work happened on, so hopping to the main queue is the
    /// caller's business.
    static func run(pairingData: Data, progress: @escaping Progress) -> Outcome {
        let pairingFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ddi-pairing-\(getpid()).plist")

        do {
            try pairingData.write(to: pairingFile, options: .atomic)
        } catch {
            return .failed("couldn't stage the pairing file: \(error.localizedDescription)")
        }

        defer { try? FileManager.default.removeItem(at: pairingFile) }

        let paths = self.paths

        do {
            // Mounting doesn't survive a reboot, so we query each launch.
            if try StikJIT.isDDIMounted(pairingFile: pairingFile) {
                Log.network.note("ddi: already mounted; nothing to do")
                return .ready
            }

            if cached(paths) {
                Log.network.note("ddi: already cached; nothing to fetch")
            } else {
                try download(to: paths, progress: progress)
            }

            Log.network.note("ddi: mounting")
            progress("Mounting DDI", 0)

            var lastLogged = -1.0
            var lastDrawn = -1.0

            try StikJIT.mountDDI(pairingFile: pairingFile, paths: paths) { fraction in
                if fraction - lastLogged >= 0.2 || fraction >= 1 {
                    lastLogged = fraction
                    Log.network.note(String(format: "ddi:   mounting %.0f%%", fraction * 100))
                }

                guard fraction - lastDrawn >= redrawStep || fraction >= 1 else { return }
                lastDrawn = fraction
                progress("Mounting DDI", fraction)
            }

            Log.network.note("ddi: mounted")

            guard try StikJIT.isDDIMounted(pairingFile: pairingFile) else {
                return .failed("the image mounted but the device doesn't see it")
            }

            return .ready
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Whether every piece is already on disk and worth using.
    ///
    /// StikJIT has `DDIPaths.allFilesUsable` for this, but it's internal.
    private static func cached(_ paths: DDIPaths) -> Bool {
        let manager = FileManager.default

        return [paths.manifestPath, paths.imagePath, paths.trustcachePath].allSatisfy { path in
            guard manager.isReadableFile(atPath: path),
                let attributes = try? manager.attributesOfItem(atPath: path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? NSNumber
            else {
                return false
            }
            return size.int64Value > 0
        }
    }

    /// Only a file bigger than this gets a bar; the rest just spin.
    private static let worthABar: Int64 = 1 << 20

    /// How far the bar has to move before it's worth redrawing.
    private static let redrawStep = 0.01

    /// Fetches each piece in turn.
    private static func download(to paths: DDIPaths, progress: @escaping Progress) throws {
        let downloader = FileDownloader()
        defer { downloader.finish() }

        for file in downloads(for: paths) {
            progress("Getting DDI", nil)

            let name = file.name
            var announced = false
            var lastDrawn = -1.0

            Log.network.note("ddi: fetching \(name)")

            try downloader.download(
                catalogue.appendingPathComponent(name),
                to: URL(fileURLWithPath: file.destination)
            ) { written, expected in
                if !announced {
                    announced = true
                    Log.network.note(
                        "ddi:   \(name) is "
                            + (expected > 0 ? "\(expected) bytes" : "of unknown length")
                            + (expected >= worthABar ? "" : "; spinning rather than drawing a bar"))
                }

                guard expected >= worthABar else { return }

                let fraction = Double(written) / Double(expected)
                guard fraction - lastDrawn >= redrawStep || fraction >= 1 else { return }
                lastDrawn = fraction

                progress("Getting DDI", fraction)
            }

            Log.network.note("ddi:   \(name) done")
        }
    }
}
