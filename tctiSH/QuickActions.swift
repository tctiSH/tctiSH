//
//  QuickActions.swift
//  The home screen long-press actions, and what a launch does with one.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// The actions offered when the app's icon is long-pressed.
enum QuickActions {

    /// What a quick action asks of a boot.
    enum Request: String {
        case withJit = "with_jit"
        case withoutJit = "without_jit"
        case recovery = "recovery"

        /// Maps the `UIApplicationShortcutItemType` values written in
        /// Info.plist.
        init?(shortcutType: String) {
            switch shortcutType {
            case "io.ara.tctish.shortcut.with-jit": self = .withJit
            case "io.ara.tctish.shortcut.without-jit": self = .withoutJit
            case "io.ara.tctish.shortcut.recovery": self = .recovery
            default:
                Log.ui.warn("no such quick action as '\(shortcutType)'")
                return nil
            }
        }

        /// Whether a boot honouring this should try to JIT, or nil where the
        /// request says nothing about JIT and the setting still stands.
        var wantsJit: Bool? {
            switch self {
            case .withJit: return true
            case .withoutJit: return false
            case .recovery: return nil
            }
        }

        /// How this reads in the log.
        var bootDescription: String {
            switch self {
            case .withJit: return "with JIT"
            case .withoutJit: return "without JIT"
            case .recovery: return "into recovery"
            }
        }
    }

    // MARK: - Arriving before the boot

    /// What this launch was asked to do, or nil for an ordinary launch.
    ///
    /// Written on the main thread during launch and read on `bootQueue`
    /// afterwards. Safe without locking because the dispatch that starts the
    /// boot happens after both writers, and nothing writes it again.
    private(set) static var request: Request?

    /// Whether this launch should try to JIT, or nil to leave it to settings.
    static var jitRequest: Bool? { request?.wantsJit }

    /// Takes a request that arrived with the launch.
    static func adopt(_ item: UIApplicationShortcutItem) {
        guard let request = Request(shortcutType: item.type) else { return }
        adopt(request, from: "the home screen")
    }

    /// Picks up a request left behind by `restart(for:)`, and spends it.
    ///
    /// Cleared as it is read. The user comes back by tapping the icon rather
    /// than the action, so the request has to outlive the process that made it
    /// -- but only just, or it would go on applying to every launch after.
    static func adoptPending() {
        let stored = UserDefaults.standard.string(forKey: pendingKey)
        UserDefaults.standard.removeObject(forKey: pendingKey)

        guard let stored, let request = Request(rawValue: stored) else { return }
        adopt(request, from: "a restart")
    }

    private static func adopt(_ value: Request, from source: String) {
        request = value
        Log.ui.note("quick action: booting \(value.bootDescription), asked for by \(source)")

        // The only one with anywhere else to be. JIT is read back out of `jitRequest` when the boot
        // settles it, whereas a recovery boot is a flag that QEMU and the terminal both read.
        if value == .recovery {
            AppDelegate.forceRecoveryBoot = true
        }
    }

    // MARK: - Arriving after the boot

    /// What the UI should do about an action that arrived warm.
    enum Arrival {

        /// The VM is already running the way the action asks.
        case alreadySatisfied(message: String, symbol: String)

        /// Only a fresh process can honour it, and tapping arranges one.
        case offersRestart(message: String, request: Request)

        /// Recovery, which is the one thing that can be done where it stands.
        case recoverInPlace
    }

    /// Posted on the main queue when a warm action needs the UI's help.
    static let didArrive = Notification.Name("io.ara.tctish.quickAction.didArrive")

    /// An arrival that has not been shown yet.
    ///
    /// The notification is the usual route: a scene connecting onto a process
    /// whose VM is already up posts before its view controller exists, and
    /// nothing would be listening. So the arrival waits here, and the view
    /// drains it as it starts observing.
    private static var unhandledArrival: Arrival?

    /// Takes the arrival that is waiting, if there is one. Main thread only.
    static func takeArrival() -> Arrival? {
        defer { unhandledArrival = nil }
        return unhandledArrival
    }

    /// Handles an action that arrived with the VM already running.
    ///
    /// Main thread only: UIKit delivers these there, and the notification goes
    /// straight to a view.
    static func performWhileRunning(_ item: UIApplicationShortcutItem) {
        guard let request = Request(shortcutType: item.type) else { return }

        Log.ui.note("quick action: asked to run \(request.bootDescription), with the VM already up")

        let arrival: Arrival
        switch request {
        case .recovery: arrival = .recoverInPlace
        case .withJit, .withoutJit: arrival = jitArrival(for: request)
        }

        unhandledArrival = arrival
        NotificationCenter.default.post(name: didArrive, object: nil)
    }

    private static func jitArrival(for request: Request) -> Arrival {
        let wanted = request.wantsJit == true

        // Falls back to what this launch asked for while the verdict is still being settled, which
        // is a second or two right at the start of one. It is the answer in all but the unluckiest
        // cases, and being wrong here only costs a restart.
        let running = JitEnablement.isJitting ?? (jitRequest ?? settingWantsJit)

        guard running != wanted else {
            return .alreadySatisfied(
                message: wanted ? "Already running with JIT" : "Already running without JIT",
                symbol: wanted ? "hare.fill" : "tortoise.fill")
        }

        return .offersRestart(
            message: wanted ? "Tap to restart with JIT" : "Tap to restart without JIT",
            request: request)
    }

    private static var settingWantsJit: Bool {
        UserDefaults.standard.string(forKey: "jit_mode") == "jit_when_possible"
    }

    // MARK: - Restarting

    /// Leaves a request for the next launch, and ends this one.
    ///
    /// As close to restarting as iOS lets an app get. The session is
    /// snapshotted exactly as backgrounding would snapshot it, the request is
    /// written where the next launch will find it, and the process ends.
    ///
    /// Only ever called with a JIT request: recovery is done where it stands
    /// and never reaches the pending slot. Worth keeping that way, because
    /// `adopt` acts on a `.recovery` it finds and a later request would not
    /// take the flag back off again.
    static func restart(for request: Request) {
        // Ahead of the banner, which owns the screen until the process ends: there is no lowering
        // it from here, so nothing may raise it without a way to reach the exit underneath.
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else {
            Log.ui.fail("no app delegate to quit through; not restarting")
            return
        }

        UserDefaults.standard.set(request.rawValue, forKey: pendingKey)

        // Now, rather than on the way out. `exit` runs none of UIKit's own shutdown, and a request
        // that never reached the disk would leave the user with a relaunch that did nothing.
        UserDefaults.standard.synchronize()

        Log.ui.note("quick action: quitting so the next launch can boot \(request.bootDescription)")

        // Up for the whole of the save, and it says what to do next because the app is about to
        // vanish off the screen and nothing else will get the chance to.
        FreezeBanner.raise("Saving; reopen tctiSH to restart")

        delegate.saveAndExit()
    }

    private static let pendingKey = "pending_quick_action"
}
