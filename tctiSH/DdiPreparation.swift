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
    ///
    /// The cryptex image since StikJIT 1.6.0, which mounts through cryptexd;
    /// the old image mounter can't mount DDIs on the iPhone 18 series of
    /// devices.
    private static let catalogue = URL(
        string: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main"
            + "/PersonalizedImages/Xcode_iOS_DDI_Cryptex")!

    /// The two cryptex-only files come last as a cache from before 1.6.0 holds
    /// the *personalized* image under the same three names, and it's the
    /// absence of these two that marks it stale. Each download is moved into
    /// place only once complete, so finding the last one means the rest are
    /// current too.
    private static func downloads(for paths: DDIPaths) -> [(name: String, destination: String)] {
        [
            ("BuildManifest.plist", paths.manifestPath),
            ("Image.dmg", paths.imagePath),
            ("Image.dmg.trustcache", paths.trustcachePath),
            ("Image.dmg.cryptex_info", paths.cryptexInfoPath),
            ("Image.dmg.root_hash", paths.rootHashPath),
        ]
    }

    enum Outcome {
        case ready
        case failed(String)
    }

    enum Removal {
        case removed(String)
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
        let pairingFile: URL

        do {
            pairingFile = try stage(pairingData, as: "ddi-pairing")
        } catch {
            return .failed("couldn't stage the pairing file: \(error.localizedDescription)")
        }

        defer { try? FileManager.default.removeItem(at: pairingFile) }

        let paths = self.paths

        do {
            // Asked every launch rather than remembered. An image-mounter DDI is gone after a
            // reboot, but a cryptex DDI stays installed and cryptexd grafts it again at boot once
            // the device is first unlocked, so it's often there before we've done anything.
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

    /// Takes every developer disk image off the device, and our downloaded copy
    /// with it.
    ///
    /// A debug tool, for getting back to a device that needs preparing.
    /// Rebooting doesn't do that: a cryptex DDI is grafted again at boot. The
    /// cache goes too, so the next preparation downloads as well as mounts.
    ///
    /// Blocking, like `run`. The message is written to be shown as it stands.
    static func removeAll(pairingData: Data) -> Removal {
        // Checked up front because StikJIT's own failure without it is an RSD tunnel error that
        // doesn't say what's missing.
        guard TunnelProbe.probeAndReport().isAvailable else {
            return .failed("The loopback VPN isn't connected. Turn it on and try again.")
        }

        let pairingFile: URL

        do {
            pairingFile = try stage(pairingData, as: "ddi-removal-pairing")
        } catch {
            return .failed("couldn't stage the pairing file: \(error.localizedDescription)")
        }

        defer { try? FileManager.default.removeItem(at: pairingFile) }

        let removal: DDIRemoval

        do {
            removal = try StikJIT.removeDDIs(pairingFile: pairingFile)
        } catch {
            // Only thrown when the device couldn't be reached, so nothing was removed.
            Log.network.note("ddi: removing failed -- \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }

        let unmounted = removal.unmountedPaths.joined(separator: ", ")
        var failures = removal.failures

        Log.network.note(
            "ddi: removed cryptex \(removal.cryptexVersion ?? "none"), "
                + "unmounted \(unmounted.isEmpty ? "nothing" : unmounted)")
        for failure in failures {
            Log.network.note("ddi:   failed while \(failure)")
        }

        // Whatever became of the device's copy. Ours is stale either way, and the point is a next
        // launch that downloads as well as mounts.
        let wasCached = downloads(for: paths).contains {
            FileManager.default.fileExists(atPath: $0.destination)
        }

        do {
            try StikJIT.resetCachedDDI(at: paths)
            Log.network.note("ddi: \(wasCached ? "deleted the cache" : "nothing cached")")
        } catch {
            failures.append("deleting the downloaded copy: \(error.localizedDescription)")
        }

        var said: [String] = []
        if let version = removal.cryptexVersion {
            said.append("Uninstalled the DDI cryptex (version \(version)).")
        }
        if !unmounted.isEmpty {
            said.append("Unmounted \(unmounted).")
        }

        // Only when every step on the device worked: a failed query isn't the same as an answer.
        if !removal.removedAnything && removal.failures.isEmpty {
            said.append("No DDI was installed.")
        }

        if failures.count == removal.failures.count {
            said.append(wasCached ? "Deleted the downloaded copy." : "Nothing was downloaded.")
        }

        // Partial success is still a failure, but it says what did go, as the next step depends on
        // it: an uninstalled cryptex won't come back at boot even if an unmount didn't take.
        guard failures.isEmpty else {
            said += failures.map { "Failed while \($0)" }
            return .failed(said.joined(separator: " "))
        }

        return .removed(said.joined(separator: " "))
    }

    /// Whether the device has a DDI mounted, for Debug Tools. Blocking.
    static func isMounted(pairingData: Data) throws -> Bool {
        let pairingFile = try stage(pairingData, as: "ddi-status-pairing")
        defer { try? FileManager.default.removeItem(at: pairingFile) }

        return try StikJIT.isDDIMounted(pairingFile: pairingFile)
    }

    /// How much of the DDI is downloaded.
    enum CacheState {
        case complete
        case partial
        case none
    }

    /// What `run` would find on disk, for Debug Tools.
    static var cacheState: CacheState {
        if cached(paths) { return .complete }

        let anything = downloads(for: paths).contains {
            FileManager.default.fileExists(atPath: $0.destination)
        }
        return anything ? .partial : .none
    }

    /// Writes the pairing data out as a file, which is what StikJIT reads.
    ///
    /// Removing it is the caller's business, once StikJIT is done with it.
    /// Every call gets a file of its own: preparing, removing and the status
    /// check can all overlap, as can two of any one of them, and none should
    /// delete another's out from under it.
    private static func stage(_ pairingData: Data, as name: String) throws -> URL {
        let pairingFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString).plist")

        try pairingData.write(to: pairingFile, options: .atomic)
        return pairingFile
    }

    /// Whether every piece is already on disk and worth using.
    ///
    /// StikJIT has `DDIPaths.allFilesUsable` for this, but it's internal.
    private static func cached(_ paths: DDIPaths) -> Bool {
        let manager = FileManager.default

        return downloads(for: paths).allSatisfy { file in
            let path = file.destination
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
