//
//  TunnelProbe.swift
//  Detection for the LocalDevVPN tunnel used to enable JIT on iOS 26+.
//
//  Copyright © 2026 Ara Adkins.
//

import Darwin
import Foundation
import Network

/// The outcome of a single probe, including how long it took to decide.
///
/// The timing matters: a live tunnel has been measured answering in ~70ms, so a
/// much slower "available" is a signal that the probe's assumptions are wrong.
enum TunnelProbeResult {
    case available(elapsed: TimeInterval)
    case unavailable(reason: String, elapsed: TimeInterval)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Checks whether the device's remote-service-discovery endpoint is reachable
/// over the LocalDevVPN tunnel.
///
/// This is the first gate of JIT enablement: without the tunnel there is no way
/// to attach a debugger, and we fall back to TCTI. Deliberately reimplemented
/// rather than borrowed from StikJIT as its probe is internal.
enum TunnelProbe {

    /// The endpoint LocalDevVPN exposes; matches StikJIT's defaults.
    static let defaultAddress = "10.7.0.1"
    static let defaultPort: UInt16 = 49152

    /// The network LocalDevVPN works on, as a dotted prefix.
    ///
    /// The /16 rather than the endpoint's own /24, as the two don't match.
    static let tunnelNetworkPrefix = "10.7."

    /// Human-readable form of the above, for the log.
    static let tunnelNetwork = "10.7.0.0/16"

    /// Guards a wedged endpoint, with the measured round trip on a live tunnel
    /// at ~7ms.
    static let defaultTimeout: TimeInterval = 0.5

    /// Reports whether a tunnel interface exists at all, keyed off the presence
    /// of an up `utun` interface rather than its address.
    static func tunnelInterfacePresent() -> Bool {
        !activeTunnelInterfaces().isEmpty
    }

    /// The up `utun` interfaces and their IPv4 addresses, for diagnosis.
    static func activeTunnelInterfaces() -> [(name: String, address: String)] {
        var found: [(name: String, address: String)] = []

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return found }
        defer { freeifaddrs(head) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let socketAddress = interface.pointee.ifa_addr,
                socketAddress.pointee.sa_family == UInt8(AF_INET),
                (interface.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                let rawName = interface.pointee.ifa_name
            else {
                continue
            }

            let name = String(cString: rawName)
            guard name.hasPrefix("utun") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    socketAddress, socklen_t(socketAddress.pointee.sa_len),
                    &host, socklen_t(host.count),
                    nil, 0, NI_NUMERICHOST) == 0
            else {
                continue
            }

            found.append((name: name, address: String(cString: host)))
        }

        return found
    }

    /// Probes the tunnel endpoint, blocking until it answers or `timeout`
    /// elapses.
    static func probe(
        address: String = defaultAddress,
        port: UInt16 = defaultPort,
        timeout: TimeInterval = defaultTimeout
    ) -> TunnelProbeResult {
        let started = DispatchTime.now()
        func elapsed() -> TimeInterval {
            let ns = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
            return TimeInterval(ns) / 1_000_000_000
        }

        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let endpointPort = NWEndpoint.Port(rawValue: port)
        else {
            return .unavailable(reason: "invalid endpoint \(address):\(port)", elapsed: elapsed())
        }

        let outcome = ProbeOutcome()
        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "io.ara.ios.tctiSH.tunnel-probe")

        let connection = NWConnection(
            host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if outcome.finish(reason: nil) { semaphore.signal() }

            case .failed(let error):
                if outcome.finish(reason: error.localizedDescription) { semaphore.signal() }

            // Reported when the path itself is unusable. Measured behaviour with the tunnel down is
            // a timeout rather than this -- 10.7.0.1 routes out the default interface and the SYNs
            // are simply dropped -- but handle it anyway for the cases where the network does say
            // no.
            case .waiting(let error):
                if outcome.finish(reason: "waiting: \(error.localizedDescription)") {
                    semaphore.signal()
                }

            default:
                break
            }
        }
        connection.start(queue: queue)

        if semaphore.wait(timeout: .now() + max(timeout, 0.01)) == .timedOut {
            _ = outcome.finish(reason: "timed out after \(Int(timeout * 1000))ms")
        }

        connection.stateUpdateHandler = nil
        connection.cancel()

        if let reason = outcome.reason {
            return .unavailable(reason: reason, elapsed: elapsed())
        }
        return .available(elapsed: elapsed())
    }

    /// Probes the tunnel and reports what happened to the log.
    ///
    /// Diagnostic only for now: nothing branches on the result yet, while we
    /// establish whether LocalDevVPN can be detected reliably.
    @discardableResult
    static func probeAndReport() -> TunnelProbeResult {
        let tunnels = activeTunnelInterfaces()

        // Log what we found either way: the endpoint's subnet turned out not to match the address
        // we're assigned, so this is how we learn the layout.
        let summary =
            tunnels.isEmpty
            ? "none"
            : tunnels.map { "\($0.name)=\($0.address)" }.joined(separator: " ")
        Log.network.note("tunnel: utun interfaces: \(summary)")

        guard !tunnels.isEmpty else {
            return .unavailable(reason: "no tunnel interface", elapsed: 0)
        }

        // A `utun` by name alone is not a LocalDevVPN tunnel: Tailscale answers to that description
        // perfectly well so we run additional probes to avoid waiting the entire timeout.
        guard tunnels.contains(where: { $0.address.hasPrefix(tunnelNetworkPrefix) }) else {
            Log.network.note("tunnel: nothing on \(tunnelNetwork), so not probing")
            return .unavailable(reason: "no tunnel interface on \(tunnelNetwork)", elapsed: 0)
        }

        let result = probe()

        switch result {
        case .available(let elapsed):
            Log.network.note(
                String(
                    format: "tunnel: %@:%u reachable in %.1fms",
                    defaultAddress, UInt32(defaultPort), elapsed * 1000))

        case .unavailable(let reason, let elapsed):
            Log.network.note(
                String(
                    format: "tunnel: %@:%u unreachable after %.1fms (%@)",
                    defaultAddress, UInt32(defaultPort), elapsed * 1000, reason))
        }

        return result
    }
}

/// Guards against the connection reporting twice, or reporting after we've
/// given up.
private final class ProbeOutcome {
    private let lock = NSLock()
    private var isFinished = false
    private var storedReason: String?

    var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedReason
    }

    /// Records the first outcome to arrive; returns whether this call was the
    /// one that settled it.
    func finish(reason: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else { return false }
        isFinished = true
        storedReason = reason
        return true
    }
}
