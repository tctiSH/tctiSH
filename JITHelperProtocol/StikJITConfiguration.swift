//
//  StikJITConfiguration.swift
//  How tctiSH and its JIT helper reach the device through StikJIT.
//
//  Copyright © 2026 Ara Adkins.
//

import StikJIT

extension StikJIT.Configuration {
    /// StikJIT's defaults with RSD port discovery off.
    ///
    /// The loopback VPN routes 10.7.0.1 back to this device, whose RSD listener
    /// is on 49152, so there is no port to discover. StikJIT 2.0 would
    /// otherwise browse Bonjour for `_remotepairing._tcp` before every call,
    /// and take the port of the first device on the network advertising it if
    /// none is on loopback, then use that port against 10.7.0.1.
    static let loopbackVPN = StikJIT.Configuration(automaticallyDiscoverRSDPort: false)
}
