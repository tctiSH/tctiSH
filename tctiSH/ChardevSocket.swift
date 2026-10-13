//
//  ChardevSocket.swift
//  A connection to one of the sockets QEMU listens on for a character device.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation

/// A connection to a Unix socket that QEMU listens on for one of its character
/// devices: a console, serial port, the user's monitor, or guest agent's port.
///
/// QEMU runs in this process on a separate thread, and listens only once it has
/// been started. Use it from the main thread, which is also where what arrives
/// is delivered. Writes go out in order on a separate queue, because one can
/// wait for a while when the guest isn't reading.
///
/// A connection can also throw away what arrives, reading it on a separate
/// queue, for a device whose output the app takes from elsewhere. Reading it
/// all the same matters: a device QEMU can't write to holds the guest up.
final class ChardevSocket {

    /// How often to try connecting, until a connection succeeds.
    private static let retryInterval: TimeInterval = 0.25

    /// How many failed attempts in a row are logged quietly. QEMU isn't
    /// listening until it has been started, which can wait on JIT being set up.
    private static let quietFailures = 40

    /// How much to read at a time.
    private static let readSize = 64 * 1024

    let path: String

    /// The name the connection goes by in the log.
    let name: String

    /// Called with each run of bytes that arrives.
    var onReceive: ((ArraySlice<UInt8>) -> Void)?

    /// Called each time a connection is made.
    var onConnect: (() -> Void)?

    var isConnected: Bool { connection != nil }

    /// How many sends haven't been written yet. One waits for as long as the
    /// guest isn't reading.
    private(set) var unsentCount = 0

    private var connection: SocketConnection?
    private var readSource: DispatchSourceRead?
    private var retryTimer: Timer?
    private var failedAttempts = 0
    private let writeQueue: DispatchQueue

    /// Whether what arrives is thrown away rather than delivered.
    private let discardsOutput: Bool

    /// Where what arrives is read: the main queue, or a separate queue when it
    /// is thrown away, so that the main thread being busy never holds the guest
    /// up.
    private let readQueue: DispatchQueue

    init(path: String, name: String, discardingOutput: Bool = false) {
        self.path = path
        self.name = name
        discardsOutput = discardingOutput
        writeQueue = DispatchQueue(label: "io.ara.tctish.chardev.\(name)", qos: .userInteractive)
        readQueue =
            discardingOutput
            ? DispatchQueue(label: "io.ara.tctish.chardev.\(name).read", qos: .utility) : .main
    }

    /// Starts trying to connect, unless already connected or trying. The first
    /// try is at once unless `waiting`.
    func start(waiting: Bool = false) {
        guard connection == nil, retryTimer == nil else { return }

        if !waiting, connect() {
            return
        }

        let timer = Timer(timeInterval: Self.retryInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if connect() {
                timer.invalidate()
                retryTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    /// Sends bytes to the far end, or drops them if there is no connection.
    func send<Bytes: Sequence<UInt8>>(_ bytes: Bytes) {
        guard let connection else { return }
        let bytes = Array(bytes)
        guard !bytes.isEmpty else { return }

        unsentCount += 1
        writeQueue.async { [weak self, name] in
            let error = connection.write(bytes)
            DispatchQueue.main.async { self?.unsentCount -= 1 }

            guard error != 0 else { return }
            Log.network.warn(
                "\(name): couldn't send \(bytes.count) bytes: \(String(cString: strerror(error)))")
        }
    }

    /// Makes one attempt to connect, and says whether it succeeded.
    private func connect() -> Bool {
        let opened = SocketConnection.open(path)

        guard case .connected(let connection) = opened else {
            failedAttempts += 1
            if case .failed(let error) = opened, failedAttempts == Self.quietFailures {
                Log.network.warn(
                    "\(name): still can't connect to \(path) after \(failedAttempts) attempts: "
                        + String(cString: strerror(error)))
            }
            return false
        }

        Log.network.note("\(name): connected after \(failedAttempts) failed attempts")
        failedAttempts = 0
        self.connection = connection

        let source = DispatchSource.makeReadSource(fileDescriptor: connection.fd, queue: readQueue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            readAvailable(from: connection, watchedBy: source)
        }

        // The connection is held until the source is cancelled, so that its descriptor isn't
        // closed, and its number given to something else, while the source is still watching it.
        source.setCancelHandler { _ = connection }
        source.resume()
        readSource = source

        onConnect?()
        return true
    }

    /// Reads what has arrived on `connection`. Runs on `readQueue`, and so
    /// touches nothing but its arguments unless that is the main queue.
    private func readAvailable(
        from connection: SocketConnection, watchedBy source: DispatchSourceRead
    ) {
        var buffer = [UInt8](repeating: 0, count: Self.readSize)
        let count = buffer.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, $0.count) }
        let error = errno

        if count > 0 {
            if !discardsOutput {
                onReceive?(buffer[..<count])
            }
            return
        }
        guard count == 0 || (error != EAGAIN && error != EINTR) else { return }

        // A closed socket stays readable, so stop watching it before this is called again.
        source.cancel()

        let reason = count == 0 ? "closed by QEMU" : String(cString: strerror(error))
        DispatchQueue.main.async { [weak self, name] in
            guard let self, self.connection === connection else { return }
            Log.network.warn("\(name): connection lost (\(reason)); reconnecting")
            disconnect()

            // Not at once: a connection that QEMU drops as soon as it is made would spin.
            start(waiting: true)
        }
    }

    private func disconnect() {
        readSource?.cancel()
        readSource = nil
        connection = nil
    }
}

/// An open socket, closed when nothing holds it any longer. Non-blocking: read
/// it once `poll` says there's something to read.
final class SocketConnection {
    let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    enum Opened {
        case connected(SocketConnection)

        /// Failed, with an errno.
        case failed(Int32)
    }

    /// Connects to the socket at `path`.
    static func open(_ path: String) -> Opened {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed(errno) }
        let connection = SocketConnection(fd: fd)

        // A write to a socket QEMU has closed fails with EPIPE rather than killing the app.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let fits = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                guard strlen(source) < capacity else { return false }
                strcpy(destination.baseAddress!.assumingMemoryBound(to: CChar.self), source)
                return true
            }
        }
        guard fits else { return .failed(ENAMETOOLONG) }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .failed(errno) }

        // Reads come from the main thread, which must never wait on the guest.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return .connected(connection)
    }

    /// Writes all of `bytes`, waiting whenever the socket is full, and returns
    /// 0, or the errno that stopped it.
    func write(_ bytes: [UInt8]) -> Int32 {
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress! + written, bytes.count - written)
            }
            if count > 0 {
                written += count
                continue
            }
            guard count < 0 else { return EPIPE }
            let error = errno
            guard error == EAGAIN || error == EINTR else { return error }

            // Full: the guest isn't reading yet. Wait until there's room again.
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&descriptor, 1, -1)
        }
        return 0
    }
}
