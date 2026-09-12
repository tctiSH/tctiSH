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
    var configServer : ConfigServer?
    var saving : Bool = false

    /// The controller used to support Picture in Picture.
    var pipController : AVPictureInPictureController?

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

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        let default_images : [String: [String:String]] = [:]

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

        // If we attempted a boot, but did not finish one, something went wrong last time.
        // Force a recovery boot.
        if UserDefaults.standard.bool(forKey: "attempting_boot") {
            AppDelegate.forceRecoveryBoot = true
        }

        // Mark ourselves as attempting a boot.
        UserDefaults.standard.set(true, forKey: "attempting_boot")
        
        // Settle how we're going to run and arrange it. 

        // This has to happen _before_ QEMU exists: it reads `usingJitHacks` and
        // `blessJitRegions` as it starts, and only asks for its code buffer to
        // be blessed if it finds a debugger already attached.
        JitEnablement.prepareForBoot()

        // Create a QEMU interface, which will launch our background kernel.
        qemu = QEMUInterface()

        // Figure out if our memory limit has changed, and thus we'll need to print a message.
        // This lets the user know to expect a delay, when appropriate.
        AppDelegate.memoryValueChanged = qemu!.memoryValueChanged()
        
        self.bootQemu()

        return true
    }
    
    
    func bootQemu() {
        // To minimize startup time, start our kernel before anything else.
        qemu!.startQemuThread(forceRecoveryBoot: AppDelegate.forceRecoveryBoot)
        AppDelegate.isFirstBoot = qemu!.isFirstBoot()

        // Finally, before starting, spawn our background configuration server.
        configServer = ConfigServer(qemuInterface: qemu!, listenImmediately: true)
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
            return();
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

