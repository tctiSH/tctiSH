//
//  GuestPreparation.swift
//  Readies the guest for a background save.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

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
/// The sync is bounded by `syncDeadline`, and both together by `deadline`.
/// Neither ever holds up the save: at the deadline the save starts, whether the
/// guest has answered or not. A trim still running then only makes the snapshot
/// bigger, as `savevm` stops the machine wherever the trim has got to. A
/// full-size snapshot beats none.
///
/// The trim is also done ahead of time, while the app is in front and the guest
/// is idle, down to `idleTrimCeiling` or the budget, whichever is more: see
/// `trimWhileIdle`. That way the trim on the way out, which has only seconds,
/// has little left to do.
enum GuestPreparation {

    /// How much file cache stays, in MiB, unless Settings says otherwise.
    static let defaultFileCacheBudget = 256

    /// The budgets Settings offers, in MiB. 0 is off: nothing is trimmed.
    static let fileCacheBudgets = [0, 128, 256, 512, 1024]

    /// The longest the sync may take, from the start of `prepareForSave`.
    ///
    /// Longer than a sync usually needs (0.5-2.5 s on an iPad after a
    /// workload), because an idle trim can be ahead of it at the agent, which
    /// answers one request at a time.
    private static let syncDeadline: TimeInterval = 8

    /// The longest the preparation may take, from the start of
    /// `prepareForSave`. It comes out of the background task's time, about 30
    /// s, which the save needs too: a trimmed guest saves in under 8 s on an
    /// iPad, and the save counts as failed at 20 s (`saveDeadline`), though it
    /// is still waited for. A trim of 0.9 GiB took 4.75 s there, so this covers
    /// one from `idleTrimCeiling` after a typical sync.
    private static let deadline: TimeInterval = 12

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
        switch GuestAgent.shared.requestWaiting(until: started + Self.syncDeadline, "sync") {
        case .done?:
            Log.qemu.note("save prep: synced in \(seconds(since: started))")

        case .failed(let why)?:
            Log.qemu.warn("save prep: sync failed: \(why)")

        case nil:
            // The agent is still syncing, and a trim would only queue behind it.
            Log.qemu.warn("save prep: no answer to sync within \(Int(Self.syncDeadline))s")
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

        guard let (before, after, took) = trimResult(words) else {
            Log.qemu.warn("save prep: trim said '\(words.joined(separator: " "))'")
            return
        }
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

    // MARK: - While idle

    /// The most file cache, in MiB, the idle trim leaves, or the budget if
    /// that's more. Some cache is kept for what runs in front; a trim down from
    /// this on the way out fits in `deadline`.
    private static let idleTrimCeiling = 1024

    /// How often the idle trim looks, while the app is in front. Each look
    /// trims for about a second at most (`TRIM_MS` in tctish-agent), so a large
    /// cache comes down over several minutes.
    private static let idleTrimInterval: TimeInterval = 30

    /// Fires `trimWhileIdle` while the app is in front.
    private static var idleTrimTimer: Timer?

    /// When the request in flight was sent, if one is. An answer may never
    /// come, as when loading a snapshot replaces the agent that was asked.
    private static var idleTrimSentAt: Date?

    /// How old a request in flight can be and still hold up the next. Under
    /// `idleTrimInterval`, so that a lost answer costs one look, not two.
    private static let idleTrimGiveUp: TimeInterval = 25

    /// Whether the agent didn't know `trim-idle`: one from an older build, in a
    /// session resumed from it, has no such request. Not asked again until
    /// Linux starts again, from this build's image.
    private static var idleTrimUnsupported = false

    /// Watches for Linux starting again, which brings this build's agent.
    private static var linuxStartObserver: NSObjectProtocol?

    /// Starts trimming the file cache while the app is in front and the guest
    /// is idle. Main thread.
    static func startTrimmingWhileIdle() {
        if linuxStartObserver == nil {
            linuxStartObserver = NotificationCenter.default.addObserver(
                forName: GuestAgent.linuxDidComeUp, object: nil, queue: .main
            ) { _ in
                idleTrimUnsupported = false
            }
        }
        guard idleTrimTimer == nil else { return }
        idleTrimTimer = Timer.scheduledTimer(withTimeInterval: idleTrimInterval, repeats: true) {
            _ in
            trimWhileIdle()
        }
    }

    /// Stops the idle trim as the app leaves the foreground; from there, the
    /// trim before the save takes over. Main thread.
    static func stopTrimmingWhileIdle() {
        idleTrimTimer?.invalidate()
        idleTrimTimer = nil
    }

    /// Asks the guest to trim its file cache to `idleTrimCeiling` if it's idle.
    /// The guest judges that by its CPU time. The app can't judge it by the
    /// terminal: it can't see what runs on a console no TTY shows.
    ///
    /// Reads `AppDelegate` directly for whether the machine is away, as
    /// `Backend` does, rather than being handed it like `prepareForSave`: this
    /// runs from a timer, with no caller to hand it.
    private static func trimWhileIdle() {
        let budget = AppSetting.fileCacheBudget.integer
        let inFlight = idleTrimSentAt.map { -$0.timeIntervalSinceNow < idleTrimGiveUp } ?? false
        guard budget > 0, !inFlight, !idleTrimUnsupported, GuestAgent.shared.isUp,
            let app = UIApplication.shared.delegate as? AppDelegate, !app.machineIsAway
        else { return }

        let sent = Date()
        idleTrimSentAt = sent
        GuestAgent.shared.request("trim-idle", String(max(budget, idleTrimCeiling))) { answer in
            if idleTrimSentAt == sent {
                idleTrimSentAt = nil
            }
            switch answer {
            case .done(let words):
                // "busy", or nothing over the ceiling, is nothing to say.
                guard let (before, after, took) = trimResult(words), before > after else { return }
                Log.qemu.note("idle trim: file cache \(before) -> \(after) MiB in \(took) ms")

            case .failed(let why):
                Log.qemu.warn("idle trim: \(why)")
                if why == "trim-idle unknown" {
                    idleTrimUnsupported = true
                }
            }
        }
    }

    /// The numbers in an answer to `reclaim` or `trim-idle`: the file cache in
    /// MiB before and after, and how long it took in ms. Nil for any other
    /// answer, such as `trim-idle`'s "busy".
    private static func trimResult(_ words: [Substring]) -> (before: Int, after: Int, took: Int)? {
        let numbers = words.compactMap { Int($0) }
        guard numbers.count == 3, numbers.count == words.count else { return nil }
        return (numbers[0], numbers[1], numbers[2])
    }

    private static func seconds(since start: DispatchTime) -> String {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        return String(format: "%.2fs", elapsed)
    }
}
