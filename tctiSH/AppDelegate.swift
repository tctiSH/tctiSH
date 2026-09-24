//
//  AppDelegate.swift
//  Primary application OS-event handlers.
//
//  Copyright (c) 2022 Katherine Temkin <k@ktemkin.com>
//

import UIKit
import AVKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var qemu: QEMUInterface?
    var configServer: ConfigServer?
    var saving: Bool = false

    /// Where the slow half of the launch runs.
    ///
    /// Serialized because the debugger has to be attached _before_ QEMU
    /// allocates its code buffer so that JIT enablement can happen. We enforce
    /// this using a serial queue without any locking.
    private let bootQueue = DispatchQueue(label: "io.ara.tctiSH.boot")

    /// The controller used to support Picture in Picture.
    var pipController: AVPictureInPictureController?

    // Global application state.
    // FIXME: move these to a nice, clean singleton
    static var forceRecoveryBoot = false
    static var usingJitHacks = false

    /// Whether QEMU should hand its code buffer to an attached debugger.
    ///
    /// True only when TXM is present, matching StikJIT's own gate as the two
    /// must never disagree.
    static var blessJitRegions = false
    static var isFirstBoot = false
    static var memoryValueChanged = false

    /// Whether the code cache size has moved since the last boot.
    ///
    /// Separate from `memoryValueChanged` because guest RAM is part of the
    /// migration stream, so changing it invalidates every snapshot and forces a
    /// cold boot. The code cache is never migrated at all, so a change here
    /// waits for a restart but never costs the session.
    static var codeCacheChanged = false

    /// Whether the machine this build makes differs from the one the last
    /// snapshot was taken of.
    ///
    /// Covers all three of QEMU's migration version, the machine's shape, and
    /// the bundled kernel and initramfs (see `VmSnapshots`). Any of them moving
    /// means the saved session describes a machine we can no longer build, so
    /// it is discarded rather than half-restored.
    static var snapshotEpochChanged = false

    /// When `didFinishLaunchingWithOptions` began.
    ///
    /// The launch screen stays up until the first frame is drawn, so every
    /// synchronous thing the launch path does is time the user spends looking
    /// at nothing.
    static var launchStarted = Date()

    /// How long since the launch began, for the log.
    static func sinceLaunch() -> String {
        String(format: "%.2fs", Date().timeIntervalSince(launchStarted))
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AppDelegate.launchStarted = Date()

        // First, so that nothing this launch logs, and nothing QEMU prints, is missed. A debugger
        // this early is Xcode's, and its console is reading stderr.
        LogFile.start(captureStderr: !jit_debugger_tracing())

        // Has to happen before launching finishes, and costs nothing if pairing is never used.
        PairingKeepAlive.register()

        let default_images: [String: [String: String]] = [:]

        // Register our default values; which will be used for any unset values.
        UserDefaults.standard.register(defaults: [
            "resume_behavior": "persistent_boot",
            "boot_snapshot": "",
            "disk_name": "disk",
            "font_size": 14,
            "theme": "solzarizedDark",
            "attempting_boot": false,
            "jit_mode": "jit_when_possible",
            "images": default_images,
            "memory": "1G",
            "code_cache_mode": CodeCache.Mode.fixed.rawValue,
            "code_cache_ceiling": CodeCache.autoCeiling,
            "code_cache_notifications": true,
        ])

        // If we attempted a boot, but did not finish one, something went wrong last time. Force a
        // recovery boot.
        if UserDefaults.standard.bool(forKey: "attempting_boot") {
            AppDelegate.forceRecoveryBoot = true
        }

        // Mark ourselves as attempting a boot.
        UserDefaults.standard.set(true, forKey: "attempting_boot")

        // `adoptPending` spends a request left behind by a restart; a shortcut in `launchOptions`
        // is one arriving by the other door, and wins if both are there. Under the scene life cycle
        // the item usually comes with the scene instead, which `handleSceneWillConnect` picks up.
        QuickActions.adoptPending()

        if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            QuickActions.adopt(item)
        }

        // Create a QEMU interface, which will launch our background kernel.
        qemu = QEMUInterface()

        // All of these are cheap, and all have to be read before the boot below records this
        // launch's values over the top of them.
        AppDelegate.memoryValueChanged = qemu!.memoryValueChanged()
        AppDelegate.codeCacheChanged = CodeCache.changedSinceLastBoot
        AppDelegate.snapshotEpochChanged = VmSnapshots.changedSinceLastBoot
        AppDelegate.isFirstBoot = qemu!.isFirstBoot()

        // Listens on a socket and does not care whether the VM is up yet, so it stays here where
        // the scene callbacks can rely on finding it.
        configServer = ConfigServer(qemuInterface: qemu!, listenImmediately: true)

        // The scene connects a few hundredths of a second after this returns and `beginBoot` is a
        // no-op by the time this fires; it is here so that a scene that somehow never connects
        // costs a late boot rather than a VM that never starts at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sceneConnectionGrace) { [weak self] in
            guard let self, !self.bootRequested else { return }

            Log.ui.warn("the scene never connected; booting anyway")
            self.beginBoot()
        }

        // Nothing slow left above, so this is the point at which UIKit is free to draw.
        Log.ui.note("launch: delegate returned at \(AppDelegate.sinceLaunch())")

        return true
    }

    /// How long to let the scene connect before booting without it.
    private static let sceneConnectionGrace: TimeInterval = 1

    /// Whether the boot has been asked for. Main thread only.
    private var bootRequested = false

    /// Takes whatever the scene brought with it, and starts the boot.
    ///
    /// The boot waits for this rather than going at the end of
    /// `didFinishLaunchingWithOptions` because a quick action does not arrive
    /// until the scene connects, and two of the three mean nothing to a process
    /// that has already allocated QEMU's code buffer.
    ///
    /// Called by `SceneDelegate`, which is where UIKit delivers this.
    func handleSceneWillConnect(shortcutItem: UIApplicationShortcutItem?) {
        if let shortcutItem {
            if bootRequested {
                // A scene connecting onto a process whose VM is already up. Nothing here can change
                // how that VM was started, so this is handled as though it had come through
                // `performActionFor`, which is what it amounts to.
                QuickActions.performWhileRunning(shortcutItem)
            } else {
                QuickActions.adopt(shortcutItem)
            }
        }

        beginBoot()
    }

    /// Settles how we're going to run, arranges it, and boots -- once, and all
    /// off the main thread.
    private func beginBoot() {
        guard !bootRequested else { return }
        bootRequested = true

        bootQueue.async { [weak self] in
            let outcome = JitEnablement.prepareForBoot()
            Log.ui.note("launch: jit settled at \(AppDelegate.sinceLaunch())")

            // QEMU's first act under TXM is to trap for its code buffer, and that trap stops every
            // thread here until the last page is blessed.
            if case .blessed = outcome, JitEnablement.expectsFreeze {
                FreezeBanner.raiseAndWait(JitEnablement.preparingMessage)
            }

            self?.bootQemu()
            Log.ui.note("launch: qemu started at \(AppDelegate.sinceLaunch())")
        }
    }

    /// Starts the VM. Runs on `bootQueue`, after JIT has been settled.
    func bootQemu() {
        qemu!.startQemuThread(forceRecoveryBoot: AppDelegate.forceRecoveryBoot)
    }

    /// Saves VM state as the app leaves the foreground.
    ///
    /// Called by `SceneDelegate`: under the scene life cycle UIKit delivers
    /// background transitions to the scene, not to the application delegate.
    func handleEnteredBackground() {
        // Going back to the background cancels a reconnect that was waiting on the save. There is
        // no foreground left to reconnect for, and `handleWillEnterForeground` will ask again.
        reconnectWhenSaved = false

        if (saving) {
            return;
        }

        if backgroundToPip() {
            Log.ui.note("switched to picture in picture")
            return ();
        }

        // Read on the main thread, because it is the view's idea of whether it is connected. Never
        // snapshot a machine that has not finished booting: there is nothing in it worth resuming,
        // and the snapshot could replace a valid one.
        guard ViewController.getCurrentTerminal()?.connected == true else {
            Log.ui.note("backgrounded before the shell connected; not saving")
            return
        }

        let application = UIApplication.shared

        saving = true

        // Off the main thread, with the assertion held until the save is really finished.
        //
        // Snapshotting a multi-gigabyte guest takes far longer than the moment iOS gives an app on
        // its way out, so it has to run under a background task, and it cannot run *on* the main
        // thread, because the expiration handler that gives the assertion back is called there.
        var task = UIBackgroundTaskIdentifier.invalid

        // Giving the assertion back and finishing the save are separate events, and conflating them
        // lets a second save start on top of the first. Expiry means "hand this back now or be
        // killed" but it does not stop the work, which carries on until its own deadlines run out.
        // `saving` therefore stays true until the work actually ends.
        let releaseAssertion = {
            guard task != .invalid else { return }

            application.endBackgroundTask(task)
            task = .invalid
        }

        task = application.beginBackgroundTask(withName: "Saving Linux state") { [weak self] in
            // Not `reportSaveFailure`: expiry means "hand the assertion back", not "the save
            // failed". The work carries on and often finishes, so the announcement is deferred and
            // withdrawn if it does; see `reportSaveRanOutOfTime`.
            self?.qemu?.reportSaveRanOutOfTime()
            releaseAssertion()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.qemu?.performBackgroundSave()

            DispatchQueue.main.async {
                releaseAssertion()
                self?.saveDidFinish()
            }
        }

        Log.ui.note("backgrounded")
    }

    /// Rebuilds the shell after a spell in the background.
    ///
    /// Held back while a save is running. `savevm` stops the guest for as long
    /// as the snapshot takes, so reconnecting into one means SSH against a
    /// machine that is not executing: the attempt fails, and the terminal's own
    /// 1.5s poll retries until the VM comes back.
    func handleWillEnterForeground() {
        guard let terminal = ViewController.getCurrentTerminal(), terminal.connected else {
            return
        }

        guard !saving else {
            Log.ui.note("returned to the foreground mid-save; reconnecting once it finishes")

            reconnectWhenSaved = true
            NotificationCenter.default.post(name: AppDelegate.reconnectDeferred, object: nil)
            return
        }

        Log.ui.note("returned to the foreground; rebuilding the shell")
        terminal.forceReconnect()
    }

    /// Whether the shell is waiting for a save before it reconnects.
    private var reconnectWhenSaved = false

    /// Whether the process is waiting for a save before it quits.
    private var exitWhenSaved = false

    /// Posted on the main queue when a reconnect has been held back.
    static let reconnectDeferred = Notification.Name("io.ara.tctish.reconnectDeferred")

    /// Marks a save finished, and does whatever was waiting on it.
    private func saveDidFinish() {
        saving = false

        // Before the reconnect, which there is no point rebuilding a shell for.
        if exitWhenSaved {
            Log.ui.note("the save finished; quitting for a quick action")
            exit(0)
        }

        guard reconnectWhenSaved else { return }
        reconnectWhenSaved = false

        // Checked again rather than assumed: a session that dropped while we were away needs no
        // forcing, because the terminal's own poll is already on it.
        guard let terminal = ViewController.getCurrentTerminal(), terminal.connected else {
            return
        }

        Log.ui.note("session save finished; rebuilding the shell")
        terminal.forceReconnect()
    }

    /// Snapshots the session and ends the process.
    ///
    /// The tail of a quick action that only a fresh launch can honour. Saving
    /// first is what makes the restart cheap: "restart with JIT" then costs the
    /// JIT decision and a tap on the icon, and not the session.
    ///
    /// Main thread only, because both the `saving` flag and the connectedness
    /// it reads live there.
    func saveAndExit() {
        // A save already running is this session's save, and it is the one that will point the next
        // launch at its snapshot. A second one must not be started on top of it: the tag is chosen
        // before the monitor lock is taken, so it would read a `resume_image` the first save has
        // not moved yet and pick the same name.
        guard !saving else {
            Log.ui.note("a save is already running; quitting once it finishes")
            exitWhenSaved = true
            return
        }

        // The same judgement backgrounding makes, for the same reason: a machine that never
        // finished booting has nothing in it worth resuming.
        guard ViewController.getCurrentTerminal()?.connected == true else {
            Log.ui.note("quitting without saving; the shell never connected")
            exit(0)
        }

        // Claimed for the same reason backgrounding claims it: so that backgrounding on the way out
        // doesn't start its own save alongside this one.
        saving = true

        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid

        let releaseAssertion = {
            guard task != .invalid else { return }

            application.endBackgroundTask(task)
            task = .invalid
        }

        // Expiry means "hand this back now", not "stop": the save carries on under its own
        // deadlines, and the exit below still happens whichever way it ends.
        task = application.beginBackgroundTask(
            withName: "Saving Linux state", expirationHandler: releaseAssertion)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.qemu?.performBackgroundSave()

            DispatchQueue.main.async {
                releaseAssertion()

                Log.ui.note("quitting for a quick action")
                exit(0)
            }
        }
    }

    /// Attempts to background the app to Picture in Picture.
    func backgroundToPip() -> Bool {
        /*
        if let term = ViewController.getCurrentTerminal() {

            // Create a controller for Picture in Picture.
            pipController = AVPictureInPictureController(contentSource: term.getPiPSource())
            if pipController == nil {
                return false
            }

            pipController?.startPictureInPicture()
        }
        */

        return false
    }

    func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
        Log.ui.note("device locked; protected data is going away")
        qemu?.stopHostChannels()
        configServer?.stop()
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        Log.ui.note("device unlocked")
        Log.network.note("reconnecting SSH channels")
        configServer?.listen()
        qemu?.startHostChannels()
        ViewController.getCurrentTerminal()?.forceReconnect()
    }

}
