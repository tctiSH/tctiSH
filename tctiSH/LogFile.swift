//
//  LogFile.swift
//  A copy of the log kept on the device, for reading back without a Mac.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation

/// The log, written to files in the app's container as well as to the unified
/// log.
///
/// The unified log is the better place to read it, but only from a Mac. On the
/// device an app can read back entries from its own process and no other, as
/// that is the only scope `OSLogStore` has on iOS, so the launch that went
/// wrong is exactly the one it can't see. These files are what Debug Tools
/// shows and shares instead.
///
/// Two files per launch: what `Log` said, and whatever the process wrote to
/// stderr. QEMU runs in this process and reports why it is giving up on stderr,
/// which otherwise goes nowhere on a device.
///
/// Bounded, so that nothing writing in a loop can fill the disk. Each file is
/// rotated at `fileCap`, keeping one older part, and the whole directory is
/// held to `budget`: the last `kept` launches, or fewer if they don't fit.
enum LogFile {

    /// One launch's files.
    struct Launch {

        /// When the launch began, from its file names.
        let started: Date

        /// What `Log` said, most recently.
        let log: URL

        /// What went to stderr, most recently. Missing for a launch that didn't
        /// capture it.
        let stderr: URL

        /// Whether this is the launch that is running now.
        let isCurrent: Bool

        /// Every file the launch has, oldest part first.
        var files: [URL] {
            [LogFile.older(log), log, LogFile.older(stderr), stderr].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
    }

    /// `Library/Logs/tctiSH`: in the container, but out of the file sharing
    /// that `Documents` is exposed to.
    static let directory: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("tctiSH", isDirectory: true)

    /// How many launches' worth are kept at most, this one included.
    private static let kept = 5

    /// How large a file may grow before it is rotated.
    private static let fileCap = 1 << 20

    /// The most the directory holds, this launch included.
    private static let budget = 10 << 20

    /// The most one launch can use: two files, each in two parts.
    ///
    /// Held back from `budget` when earlier launches are pruned, since this one
    /// hasn't written anything yet. Either file can overshoot its cap by
    /// whatever lands before it's noticed, so this is close rather than exact.
    private static let launchMaximum = 4 * fileCap

    /// Where every write happens, so no caller waits on the disk.
    ///
    /// Serial, and the only thing that touches the state below.
    private static let queue = DispatchQueue(label: "io.ara.tctiSH.log-file", qos: .utility)

    /// This launch's log, or -1 if it isn't open, in which case lines are only
    /// in the unified log.
    private static var descriptor: Int32 = -1

    /// How much of the current log part has been written.
    private static var logBytes = 0

    /// Watches the stderr file for growth. Nil when stderr isn't captured.
    private static var stderrWatch: DispatchSourceFileSystemObject?

    /// The name all of this launch's files share.
    private static var currentStamp: String?

    /// Sortable, and safe as a file name.
    ///
    /// In UTC, because sorting is how the oldest launches are found. Local time
    /// runs the same hour twice when the clocks go back, and a launch in the
    /// second of them would sort before one in the first.
    private static let stampFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return format
    }()

    private static let lineFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "HH:mm:ss.SSS"
        return format
    }()

    /// Where a file's older part goes when it's rotated.
    static func older(_ file: URL) -> URL {
        URL(fileURLWithPath: file.path + ".1")
    }

    /// Opens this launch's files, and drops the oldest.
    ///
    /// Call as early in the launch as possible. Anything logged before this is
    /// only in the unified log, and anything QEMU says before it goes nowhere.
    ///
    /// Leaves stderr alone when `captureStderr` is false. Under Xcode that's
    /// where its console reads from, and taking it away would hide QEMU's
    /// output from exactly the person most likely to want it.
    static func start(captureStderr: Bool) {
        queue.sync {
            guard currentStamp == nil else { return }

            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            } catch {
                return
            }

            // Logs aren't worth a backup's space, and everything under Library except Caches is
            // backed up otherwise. Set on the directory, which covers everything in it.
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)

            // Before this launch's files exist, so they're never counted against themselves.
            prune()

            let stamp = stampFormat.string(from: Date())
            currentStamp = stamp

            // O_APPEND and one write(2) per line, with no buffer in between. A line is on disk once
            // `write` returns, so it survives the process dying straight afterwards, which is
            // precisely when it matters.
            descriptor = openForAppending(logFile(stamp))

            if captureStderr {
                redirectStderr(to: stderrFile(stamp))
            }
        }
    }

    /// Adds a line to this launch's log. Returns at once.
    static func append(area: String, level: String?, message: String) {
        let when = Date()

        queue.async {
            guard descriptor >= 0 else { return }

            let prefix = level.map { "\($0): " } ?? ""
            let line = "\(lineFormat.string(from: when)) \(area) \(prefix)\(message)\n"

            var bytes = Array(line.utf8)[...]
            while !bytes.isEmpty {
                let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                guard written > 0 else { return }
                bytes = bytes.dropFirst(written)
                logBytes += written
            }

            if logBytes >= fileCap, let stamp = currentStamp {
                close(descriptor)
                rotate(logFile(stamp))
                descriptor = openForAppending(logFile(stamp))
                logBytes = 0
            }
        }
    }

    /// The launches kept, newest first.
    static func launches() -> [Launch] {
        queue.sync {
            launchStamps().compactMap { stamp in
                guard let started = stampFormat.date(from: stamp) else { return nil }

                return Launch(
                    started: started,
                    log: logFile(stamp),
                    stderr: stderrFile(stamp),
                    isCurrent: stamp == currentStamp)
            }
        }
    }

    // MARK: - stderr

    /// Points fd 2 at `file`, and watches it for passing `fileCap`. Queue only.
    ///
    /// Nothing sees the writes themselves: QEMU makes them straight to the
    /// descriptor. So the file is watched instead, and when it has grown too
    /// large it is renamed out of the way and fd 2 pointed at a fresh one.
    /// `dup2` replaces the descriptor in one step, so a write lands in one file
    /// or the other and is never lost. Anything written between the rename and
    /// the `dup2` goes to the older part, which is where it belongs anyway.
    private static func redirectStderr(to file: URL) {
        let captured = openForAppending(file)
        guard captured >= 0 else { return }

        dup2(captured, STDERR_FILENO)
        close(captured)

        // A descriptor of its own, for events only: watching fd 2 itself would lose the watch at
        // the `dup2` that rotates it.
        let watched = open(file.path, O_EVTONLY)
        guard watched >= 0 else { return }

        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watched, eventMask: .extend, queue: queue)

        // Above the queue's own utility QoS. How far a flood overshoots the cap is however much it
        // writes before this runs, and a busy guest is exactly what would keep a utility handler
        // waiting.
        watch.setEventHandler(qos: .userInitiated, flags: .enforceQoS) {
            var status = stat()
            guard fstat(STDERR_FILENO, &status) == 0, status.st_size >= fileCap else { return }

            stderrWatch?.cancel()
            stderrWatch = nil

            rotate(file)
            redirectStderr(to: file)
        }

        watch.setCancelHandler { close(watched) }
        watch.resume()
        stderrWatch = watch
    }

    // MARK: - Files

    private static func logFile(_ stamp: String) -> URL {
        directory.appendingPathComponent("\(stamp).log")
    }

    private static func stderrFile(_ stamp: String) -> URL {
        directory.appendingPathComponent("\(stamp).stderr")
    }

    private static func openForAppending(_ file: URL) -> Int32 {
        open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    }

    /// Moves `file` to its older part, replacing any there already.
    private static func rotate(_ file: URL) {
        Darwin.rename(file.path, older(file).path)
    }

    /// Every launch with files in `directory`, newest first. Queue only.
    ///
    /// A launch's files all start with its stamp, which has no dots in it, so
    /// everything up to the first dot names the launch.
    private static func launchStamps() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let stamps = Set(names.compactMap { $0.split(separator: ".").first.map(String.init) })

        // Anything else in here isn't a launch, and would otherwise take one of `kept`'s places.
        return stamps.filter { stampFormat.date(from: $0) != nil }.sorted(by: >)
    }

    /// Deletes earlier launches until what's left is within `kept`, and within
    /// `budget` less what this launch may yet use. Queue only.
    ///
    /// Newest first, so a launch too large to fit takes every older one with
    /// it: keeping an old launch in place of a newer one is never the trade
    /// anyone would make.
    private static func prune() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let allowance = budget - launchMaximum
        var used = 0
        var keeping = true

        for (index, stamp) in launchStamps().enumerated() {
            let files = names.filter { $0.hasPrefix(stamp + ".") }
                .map { directory.appendingPathComponent($0) }

            let size = files.reduce(0) { total, file in
                total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }

            // One fewer than `kept`, as this launch is about to be one of them. Once one goes,
            // every older one goes with it, however small.
            keeping = keeping && index < kept - 1 && used + size <= allowance

            if keeping {
                used += size
            } else {
                for file in files {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
