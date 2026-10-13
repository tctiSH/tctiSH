//
//  FileTail.swift
//  Following a file that something else appends to.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation

/// Follows a file that something else appends to, as `tail -f` does, and
/// delivers what is added on the main queue.
///
/// Made for QEMU's copy of what a character device sent (its `logfile`), which
/// QEMU keeps whether or not the app is connected. Reading the device's output
/// from there rather than from its socket loses nothing to the moments before
/// the app connects, or between connections.
///
/// The writer must append (`logappend=on`): once the file passes
/// `trimThreshold`, what has been read is cut from it, so that a long session
/// doesn't fill the disk, and a writer that kept track of its offset would then
/// leave a hole the size of what was cut. What the writer adds between the last
/// read and the cut is lost, which takes a write landing in the same moment,
/// once every few megabytes.
///
/// Use it from the main thread.
final class FileTail {

    /// How often to look for the file, until it exists.
    private static let retryInterval: TimeInterval = 0.1

    /// How much to read at a time.
    private static let readSize = 64 * 1024

    /// How large the file may grow before what has been read is cut from it.
    private static let trimThreshold: off_t = 4 << 20

    let path: String

    /// The name it goes by in the log.
    let name: String

    /// Called with each run of bytes added to the file.
    var onReceive: ((ArraySlice<UInt8>) -> Void)?

    private var descriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var retryTimer: Timer?

    /// Set once a trim has failed, so it isn't tried, and logged, on every
    /// read.
    private var trimFailed = false

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    /// Starts following the file, from its start, once it exists. Does nothing
    /// if already following or waiting.
    func start() {
        guard descriptor < 0, retryTimer == nil else { return }

        if open() {
            return
        }
        let timer = Timer(timeInterval: Self.retryInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if open() {
                timer.invalidate()
                retryTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    /// Makes one attempt to open the file, and says whether it succeeded.
    private func open() -> Bool {
        // Writable, so that what has been read can be cut from it.
        let fd = Darwin.open(path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { return false }
        descriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // Replaced, as by a new launch of the writer: start again on the new file.
                readAvailable()
                Log.fs.note("\(name): \(path) was replaced; following the new one")
                stop()
                start()
                return
            }
            readAvailable()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source

        // Whatever is already there.
        readAvailable()
        return true
    }

    private func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func readAvailable() {
        guard descriptor >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: Self.readSize)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, $0.count)
            }
            guard count > 0 else { break }
            onReceive?(buffer[..<count])
        }

        // Everything written so far has been read. Cut it, if there is enough to be worth it.
        let offset = lseek(descriptor, 0, SEEK_CUR)
        guard offset >= Self.trimThreshold, !trimFailed else { return }
        if ftruncate(descriptor, 0) == 0 {
            lseek(descriptor, 0, SEEK_SET)
        } else {
            trimFailed = true
            Log.fs.warn("\(name): couldn't trim \(path): \(String(cString: strerror(errno)))")
        }
    }
}
