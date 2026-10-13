//
//  GuestPreparation.swift
//  Readies the guest for a background save.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation

/// Readies the guest for a background save, through `tctish-agent`:
///
/// - **Writes out dirty data.** A save that works holds the disk as well as
///   RAM, so this matters when the save fails and the next launch cold boots,
///   and for shared folders, whose writes reach the Files app only once
///   written out.
/// - **Trims the file cache to a budget.** After a workload, most of the
///   guest's memory is file cache, all of which goes into the snapshot and
///   back into RAM on return. The guest's kernel drops the least used first;
///   the budget sets how much stays. The cost is a colder cache on return.
///
/// Both together are bounded by `deadline`. If the guest doesn't answer, the
/// save goes ahead anyway: a full-size snapshot beats none.
enum GuestPreparation {

    /// How much file cache stays, in MiB, unless Settings says otherwise.
    static let defaultFileCacheBudget = 256

    /// The budgets Settings offers, in MiB. 0 is off: nothing is trimmed.
    static let fileCacheBudgets = [0, 128, 256, 512, 1024]

    /// The longest the preparation may take. It comes out of the background
    /// task's time, which the save needs too.
    private static let deadline: TimeInterval = 5

    /// How long to wait after a trim for the guest to hand the memory back to
    /// iOS. Free page reporting waits 2 s (`PAGE_REPORTING_DELAY`) first, and
    /// until then the freed pages still hold data that the save would write.
    private static let reportingDelay: TimeInterval = 2.5

    /// The smallest trim, in MiB, worth waiting for.
    private static let worthReporting = 32

    /// Prepares the guest, keeping `fileCacheBudget` MiB of file cache (all of
    /// it if 0). Off the main thread; returns when done or out of time. Skips
    /// the trim if `stillAway` says the app is back in the foreground, where
    /// the cache is in use again.
    static func prepareForSave(fileCacheBudget: Int, stillAway: () -> Bool) {
        let started = DispatchTime.now()
        let deadline = started + Self.deadline

        // Dirty pages can't be trimmed until written, so this goes first.
        switch GuestAgent.shared.requestWaiting(until: deadline, "sync") {
        case .done?:
            Log.qemu.note("save prep: synced in \(seconds(since: started))")

        case .failed(let why)?:
            Log.qemu.warn("save prep: sync failed: \(why)")

        case nil:
            // The agent is still syncing, and a trim would only queue behind it.
            Log.qemu.warn("save prep: no answer to sync within \(Int(Self.deadline))s")
            return
        }

        guard fileCacheBudget > 0 else { return }
        guard stillAway() else {
            Log.qemu.note("save prep: back in the foreground; not trimming")
            return
        }

        let trimmed = GuestAgent.shared.requestWaiting(
            until: deadline, "reclaim", String(fileCacheBudget))
        guard case .done(let words)? = trimmed else {
            if case .failed(let why)? = trimmed {
                Log.qemu.warn("save prep: trim failed: \(why)")
            } else {
                Log.qemu.warn("save prep: no answer to trim by \(Int(Self.deadline))s")
            }
            return
        }

        let numbers = words.compactMap { Int($0) }
        guard numbers.count == 3 else {
            Log.qemu.warn("save prep: trim said '\(words.joined(separator: " "))'")
            return
        }
        let (before, after, took) = (numbers[0], numbers[1], numbers[2])
        Log.qemu.note(
            "save prep: file cache \(before) -> \(after) MiB (budget \(fileCacheBudget)) "
                + "in \(took) ms")

        // Only when enough was trimmed, and no longer than the time left.
        guard before - after >= Self.worthReporting else { return }
        let now = DispatchTime.now()
        guard now < deadline else { return }
        let left = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1e9
        Thread.sleep(forTimeInterval: min(Self.reportingDelay, left))
        Log.qemu.note("save prep: done in \(seconds(since: started))")
    }

    private static func seconds(since start: DispatchTime) -> String {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        return String(format: "%.2fs", elapsed)
    }
}
