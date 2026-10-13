//
//  GuestClock.swift
//  Keeps the guest's clock and time zone the host's.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// Keeps the guest's clock and time zone the device's, through `tctish-agent`.
///
/// QEMU catches the guest's clock up whenever the machine starts or is loaded,
/// but it once left a session three days behind, and a cold boot starts from
/// the RTC, which has one-second resolution. So the app also sends the time
/// whenever the guest could have lost track: when Linux comes up (a boot, a
/// resume, a reset), when the machine is back after the app was away, and when
/// iOS says the time has changed.
///
/// The zone is sent at the same moments, and whenever iOS's changes. Programs
/// started after a change use the new zone; ones already running keep the old
/// one until restarted, which a pill says.
///
/// Main thread.
final class GuestClock {

    static let shared = GuestClock()

    /// Posted on the main queue when the guest's zone changes from one zone to
    /// another, with the new zone's name as the object. Not when a guest that
    /// had none gets one, as on a new disk.
    static let zoneDidChange = Notification.Name("io.ara.tctish.guestZoneDidChange")

    private init() {}

    /// Starts following the device's time and zone.
    func start() {
        let center = NotificationCenter.default
        for name in [
            GuestAgent.linuxDidComeUp, AppDelegate.machineIsBack,
            UIApplication.significantTimeChangeNotification, .NSSystemTimeZoneDidChange,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sendTimeAndZone(because: name.rawValue)
            }
        }
    }

    private func sendTimeAndZone(because reason: String) {
        // Not while the machine is stopped for a save or parked: the request would wait in the
        // socket and be out of date by the time it ran. The machine's return sends it again.
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        guard GuestAgent.shared.isUp, appDelegate?.machineIsAway != true else { return }

        sendTime(because: reason)
        sendZone()
    }

    private func sendTime(because reason: String) {
        // Stamped as late as possible. The guest ends up behind by however long the request takes
        // to arrive, which the agent ignores below a quarter second.
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        let time = String(format: "%ld.%09ld", now.tv_sec, now.tv_nsec)

        GuestAgent.shared.request("time", time) { answer in
            switch answer {
            case .done(let words) where words.first == "stepped":
                Log.qemu.note(
                    "guest clock: set, \(words.dropFirst().first ?? "?")s out (\(reason))")

            case .done(let words):
                Log.qemu.note(
                    "guest clock: kept, \(words.dropFirst().first ?? "?")s out (\(reason))")

            case .failed(let why):
                Log.qemu.warn("guest clock: not set: \(why)")
            }
        }
    }

    private func sendZone() {
        // Foundation caches the zone until told to look again.
        NSTimeZone.resetSystemTimeZone()
        let zone = TimeZone.current.identifier

        GuestAgent.shared.request("zone", zone) { answer in
            switch answer {
            case .done(let words) where words.first == "changed":
                let old = words.dropFirst().first ?? "-"
                Log.qemu.note("guest zone: now \(zone), was \(old)")

                // Programs may be running on the old one.
                if old != "-" {
                    NotificationCenter.default.post(name: Self.zoneDidChange, object: zone)
                }

            case .done:
                break

            case .failed(let why):
                Log.qemu.warn("guest zone: not set to \(zone): \(why)")
            }
        }
    }
}
