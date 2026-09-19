//
//  LocalNetworkPermission.swift
//  Raising the local-network prompt deliberately, rather than by accident.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import Network

/// Asks for local-network access at a moment of our choosing.
///
/// This publishes and browses for a service type that means nothing to anybody,
/// purely to ensure that the prompt appears and to find out what the user said.
/// Seeing our own advertisement come back is the only positive signal
/// available: there is no "authorized" state to read.
enum LocalNetworkPermission {

    /// A type nothing else browses for.
    static let probeType = "_tctishprobe._tcp"

    /// How long to wait for our own advertisement to come back.
    ///
    /// Long, because the clock includes the user reading a dialog and deciding.
    static let timeout: TimeInterval = 30

    /// Requests access and reports whether the local network appears usable.
    ///
    /// `completion` runs on the main queue exactly once. A `false` means either
    /// a refusal or a silence we cannot tell apart from one.
    static func request(completion: @escaping (Bool) -> Void) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let settled = Settled()
        var listener: NWListener?
        var browser: NWBrowser?

        func finish(_ granted: Bool) {
            guard settled.claim() else { return }

            listener?.cancel()
            browser?.cancel()
            listener = nil
            browser = nil

            DispatchQueue.main.async { completion(granted) }
        }

        listener = try? NWListener(using: parameters)
        guard let listener else {
            Log.network.note("permission: could not listen to probe the local network")
            finish(false)
            return
        }

        listener.service = NWListener.Service(name: "tctiSH", type: probeType)
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.network.note("permission: probe listener failed (\(error))")
                finish(false)
            }
        }

        let discovery = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: parameters)
        browser = discovery
        discovery.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.network.note("permission: probe browser failed (\(error))")
                finish(false)
            }
        }
        discovery.browseResultsChangedHandler = { results, _ in
            // Our own service coming back is the signal. Nothing else publishes this type, so
            // anything at all here means multicast is working for us.
            if !results.isEmpty { finish(true) }
        }

        listener.start(queue: .main)
        discovery.start(queue: .main)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if settled.isPending {
                Log.network.note("permission: no answer within \(Int(timeout))s")
            }
            finish(false)
        }
    }
}

/// Makes sure the completion runs once, whichever handler gets there first.
private final class Settled {
    private let lock = NSLock()
    private var claimed = false

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !claimed
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !claimed else { return false }
        claimed = true
        return true
    }
}
