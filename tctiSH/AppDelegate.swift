//
//  AppDelegate.swift
//  Primary application OS-event handlers.
//
//  Copyright (c) 2022 Katherine Temkin <k@ktemkin.com>
//

import UIKit
import AVKit
import Atomics

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var qemu: QEMUInterface?
    var configServer: ConfigServer?
    var saving: Bool = false

    /// The snapshot the machine is parked on, while parked: stopped, saved, and
    /// its RAM given back to iOS. Main thread only.
    ///
    /// See `handleEnteredBackground` and `unpark`.
    private var parkedTag: String?

    /// Whether an `unpark` is running. Main thread only.
    private var unparking = false

    /// Whether the code cache was handed back while parked, and has to be
    /// prepared again before the machine may run. Main thread only.
    private var codeCacheNeedsPreparing = false

    /// Whether the app is in the background.
    ///
    /// Atomic because the save reads it from its own thread at the moment it
    /// decides whether to park: someone who came back while the snapshot was
    /// being written doesn't want the machine parked under them.
    private let away = ManagedAtomic<Bool>(false)

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

    /// Whether QEMU starts on native code rather than TCTI. It can be switched
    /// while it runs; see `Backend`.
    static var startsNative = false

    /// Whether QEMU should hand native code's buffer to an attached debugger.
    ///
    /// True only when TXM is present, matching StikJIT's own gate as the two
    /// must never disagree, and whichever backend the VM starts on.
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
            "jit_mode": ExecutionMode.dynamicAuto.rawValue,
            "flush_jit_buffers": false,
            "images": default_images,
            "memory": "1G",
            "code_cache_mode": CodeCache.Mode.fixed.rawValue,
            "code_cache_ceiling": CodeCache.autoCeiling,
            "code_cache_notifications": true,
            "park_in_background": false,
            "release_code_cache_in_background": false,
        ])

        // Before anything reads it.
        ExecutionMode.migrate()

        // If we attempted a boot, but did not finish one, something went wrong last time. Force a
        // recovery boot.
        if UserDefaults.standard.bool(forKey: "attempting_boot") {
            AppDelegate.forceRecoveryBoot = true
        }

        // Mark ourselves as attempting a boot.
        UserDefaults.standard.set(true, forKey: "attempting_boot")

        // Under the scene life cycle the item usually comes with the scene instead, which
        // `handleSceneWillConnect` picks up.
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

            DispatchQueue.main.async { Backend.booted() }
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
        away.store(true, ordering: .relaxed)

        // An unpark in flight saves again when it finishes, seeing that we are away; a parked
        // machine is already saved, and there is nothing running to save.
        if saving || unparking || parkedTag != nil {
            return
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

        // Read here rather than on the save's thread, so that a change made while a save is running
        // takes effect at the next one rather than halfway through this one. The code cache only
        // ever goes with the machine's memory: a machine that isn't parked is still running on it.
        let parking = AppSetting.parkInBackground.bool
        let releasingCode = parking && AppSetting.releaseCodeCacheInBackground.bool

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parked = self?.save(thenPark: parking, releasingCode: releasingCode)

            DispatchQueue.main.async {
                releaseAssertion()
                self?.saveDidFinish(
                    parkedOn: parked?.tag, codeReleased: parked?.codeReleased ?? false)
            }
        }

        Log.ui.note("backgrounded")
    }

    /// Saves the session and, if asked and still away, parks the machine, and
    /// then hands its code cache back too if asked.
    ///
    /// Returns what it is parked on, or nil if it is running. Off the main
    /// thread.
    private func save(thenPark parking: Bool, releasingCode: Bool) -> (
        tag: String, codeReleased: Bool
    )? {
        guard let qemu else { return nil }

        guard case .savedAndStopped(let tag) = qemu.performBackgroundSave(leavingStopped: parking)
        else {
            return nil
        }

        // Decided at the last moment. Coming back mid-save means a reconnect is waiting and parking
        // would only make it wait for a load as well.
        guard away.load(ordering: .relaxed) else {
            qemu.continueStopped()
            return nil
        }

        // Running again if it didn't park; see `park`.
        guard qemu.park() else { return nil }

        Log.qemu.note("park: parked on '\(tag)'")

        // Only now, with the machine parked: nothing can run into the cache until it has been
        // prepared again.
        let codeReleased = releasingCode && CodeCacheMonitor.releaseWhileParked()

        // On TCTI, native code's buffer is idle and goes whenever Flush JIT Buffers says it should.
        Backend.releaseNativeNow()
        return (tag, codeReleased)
    }

    /// Rebuilds the shell after a spell in the background.
    ///
    /// Held back while a save is running. `savevm` stops the guest for as long
    /// as the snapshot takes, so reconnecting into one means SSH against a
    /// machine that is not executing: the attempt fails, and the terminal's own
    /// 1.5s poll retries until the VM comes back.
    func handleWillEnterForeground() {
        away.store(false, ordering: .relaxed)

        if parkedTag == nil {
            Backend.conditionsMayHaveChanged()
        }

        // Before looking at the terminal, which may well say it is connected: a parked machine has
        // to be brought back whatever the view thinks, or it stays parked for good.
        if let tag = parkedTag {
            unpark(tag: tag)
            return
        }

        guard let terminal = ViewController.getCurrentTerminal(), terminal.connected else {
            return
        }

        guard !saving, !unparking else {
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

    /// Whether the machine is being saved, is parked, or is coming back from a
    /// park, any of which a switch of backend must wait out. Main thread.
    var machineIsAway: Bool {
        saving || parkedTag != nil || unparking
    }

    /// Posted on the main queue when a reconnect has been held back.
    static let reconnectDeferred = Notification.Name("io.ara.tctish.reconnectDeferred")

    /// Marks a save finished, and does whatever was waiting on it.
    private func saveDidFinish(parkedOn tag: String? = nil, codeReleased: Bool = false) {
        saving = false
        parkedTag = tag
        codeCacheNeedsPreparing = codeReleased

        // Parked just as someone came back. `handleWillEnterForeground` saw a save running and left
        // it to us, or saw a dropped shell and left nothing at all; either way a parked machine in
        // the foreground has to come back.
        if let tag, !away.load(ordering: .relaxed) {
            reconnectWhenSaved = false
            unpark(tag: tag)
            return
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

    /// Brings a parked machine back, and the shell with it.
    ///
    /// Main thread. The load itself runs off it, because it reads the whole
    /// session back from storage, and the boot pill says what is going on.
    private func unpark(tag: String) {
        guard let qemu, !unparking else { return }

        unparking = true
        NotificationCenter.default.post(name: AppDelegate.unparkStarted, object: nil)
        Log.ui.note("returned to the foreground parked; unparking '\(tag)'")

        // The code cache first, if it went while parked: the machine must not run a single
        // instruction before it is prepared, and under TXM this is the freeze.
        prepareCodeCacheIfNeeded { [weak self] prepared in
            guard prepared else {
                self?.unparkDidFinish(unparked: false)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let unparked = qemu.unpark(tag: tag)

                DispatchQueue.main.async {
                    self?.unparkDidFinish(unparked: unparked)
                }
            }
        }
    }

    /// Prepares a code cache that was handed back while parked, as at launch,
    /// and says whether the machine may now run. Main thread.
    private func prepareCodeCacheIfNeeded(then proceed: @escaping (Bool) -> Void) {
        guard codeCacheNeedsPreparing else {
            proceed(true)
            return
        }

        CodeCacheMonitor.prepareAfterPark { [weak self] prepared in
            if prepared {
                self?.codeCacheNeedsPreparing = false
            }
            proceed(prepared)
        }
    }

    /// Posted on the main queue when a parked machine starts coming back.
    static let unparkStarted = Notification.Name("io.ara.tctish.unparkStarted")

    /// Posted on the main queue when a parked machine couldn't be brought back,
    /// and is waiting for `recoverFromFailedUnpark`.
    static let unparkDidFail = Notification.Name("io.ara.tctish.unparkDidFail")

    /// The ways on from a parked machine that wouldn't come back.
    enum UnparkRecovery {
        case retry

        /// Quit, so that the next launch resumes from the snapshot on disk.
        case quit

        /// A cold boot. The session is lost.
        case startAfresh
    }

    /// Acts on the answer to `unparkDidFail`, and returns whether it did: not
    /// if the machine has meanwhile come back, or is on its way. Main thread.
    @discardableResult
    func recoverFromFailedUnpark(_ choice: UnparkRecovery) -> Bool {
        guard let tag = parkedTag, !unparking else { return false }

        switch choice {
        case .retry:
            unpark(tag: tag)

        case .quit:
            Log.ui.note("quitting to resume '\(tag)' from a fresh launch")
            exit(0)

        case .startAfresh:
            // Counted as an unpark, which it replaces, so that a return meanwhile doesn't start a
            // second one over the top of it.
            unparking = true

            // A reset machine runs on the code cache as much as an unparked one does, and QEMU
            // won't start it until the cache is prepared.
            prepareCodeCacheIfNeeded { [weak self] prepared in
                guard let self else { return }
                self.unparking = false

                guard prepared else {
                    Log.qemu.fail("park: can't start afresh without a code cache; asking again")
                    NotificationCenter.default.post(name: AppDelegate.unparkDidFail, object: nil)
                    return
                }

                Log.qemu.note("park: giving up on '\(tag)'; booting Linux afresh")

                // Parked until the reset has actually been asked for. Let go of before then, a
                // failure would leave a parked machine that nothing ever tries to bring back.
                guard self.qemu?.requestRecoveryBoot() == true else {
                    Log.qemu.fail("park: the reset didn't go through; asking again")
                    NotificationCenter.default.post(name: AppDelegate.unparkDidFail, object: nil)
                    return
                }
                self.parkedTag = nil
            }
        }

        return true
    }

    /// Does whatever was waiting on an unpark.
    private func unparkDidFinish(unparked: Bool) {
        unparking = false

        guard unparked else {
            // Still parked, and QEMU won't run it. What was in memory is in the snapshot on disk,
            // which the next launch would try again.
            //
            // Not decided here: trying again, quitting to try from a fresh launch, and a cold boot
            // each cost something different, and only one of them loses the session. Left parked
            // meanwhile, which is safe; a return with the question unanswered simply tries again.
            Log.qemu.fail("park: could not bring the session back; asking what to do")
            NotificationCenter.default.post(name: AppDelegate.unparkDidFail, object: nil)
            return
        }

        parkedTag = nil
        Log.jit.note(
            "backend: back from the park on \(Backend.current?.name ?? "?"), JIT buffers "
                + (Backend.nativePrepared ? "prepared" : "not prepared"))
        Backend.conditionsMayHaveChanged()

        // Away again before the load finished. It's running now, so it gets saved (and parked)
        // again, as if it had just been backgrounded.
        if away.load(ordering: .relaxed) {
            handleEnteredBackground()
            return
        }

        // A dropped session needs no forcing, as elsewhere: the terminal's own poll is already on
        // it, and brings the pill down when it connects.
        guard let terminal = ViewController.getCurrentTerminal(), terminal.connected else {
            return
        }

        Log.ui.note("unparked; rebuilding the shell")
        terminal.forceReconnect()
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

        // Not into a parked machine, which can't answer; the unpark reconnects once it is running.
        guard parkedTag == nil, !unparking else { return }

        ViewController.getCurrentTerminal()?.forceReconnect()
    }

}
