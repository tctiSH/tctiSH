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
        ])

        // If we attempted a boot, but did not finish one, something went wrong
        // last time. Force a recovery boot.
        if UserDefaults.standard.bool(forKey: "attempting_boot") {
            AppDelegate.forceRecoveryBoot = true
        }

        // Mark ourselves as attempting a boot.
        UserDefaults.standard.set(true, forKey: "attempting_boot")

        // Create a QEMU interface, which will launch our background kernel.
        qemu = QEMUInterface()

        // Both of these are cheap.
        AppDelegate.memoryValueChanged = qemu!.memoryValueChanged()
        AppDelegate.isFirstBoot = qemu!.isFirstBoot()

        // Listens on a socket and does not care whether the VM is up yet, so it
        // stays here where the scene callbacks can rely on finding it.
        configServer = ConfigServer(qemuInterface: qemu!, listenImmediately: true)

        // Settle how we're going to run, arrange it, and boot, all off the main
        // thread.
        bootQueue.async { [weak self] in
            let outcome = JitEnablement.prepareForBoot()
            Log.ui.note("launch: jit settled at \(AppDelegate.sinceLaunch())")

            // QEMU's first act under TXM is to trap for its code buffer, and
            // that trap stops every thread here until the last page is blessed.
            if case .blessed = outcome, JitEnablement.expectsFreeze {
                FreezeBanner.raiseAndWait(JitEnablement.preparingMessage)
            }

            self?.bootQemu()
            Log.ui.note("launch: qemu started at \(AppDelegate.sinceLaunch())")
        }

        // Nothing slow left above, so this is the point at which UIKit is free
        // to draw.
        Log.ui.note("launch: delegate returned at \(AppDelegate.sinceLaunch())")

        return true
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
        if (saving) {
            return;
        }

        if backgroundToPip() {
            Log.ui.note("switched to picture in picture")
            return ();
        }

        let application = UIApplication.shared

        saving = true
        let taskIdentifier = application.beginBackgroundTask {}
        qemu?.performBackgroundSave()
        application.endBackgroundTask(taskIdentifier)
        saving = false

        Log.ui.note("backgrounded")
    }

    /// Rebuilds the shell after a spell in the background.
    func handleWillEnterForeground() {
        guard let terminal = ViewController.getCurrentTerminal(), terminal.connected else {
            return
        }

        Log.ui.note("returned to the foreground; rebuilding the shell")
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
        ViewController.getCurrentTerminal()?.forceReconnect()
    }

}
