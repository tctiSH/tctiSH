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
    var window: UIWindow?
    var qemu: QEMUInterface?
    var configServer : ConfigServer?
    var saving : Bool = false

    /// The controller used to support Picture in Picture.
    var pipController : AVPictureInPictureController?

    // Global application state.
    // FIXME: move these to a nice, clean singleton
    static var forceRecoveryBoot = false
    static var usingJitHacks = false
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

        let settingsAllowJit = UserDefaults.standard.string(forKey: "jit_mode") == "jit_when_possible"

#if targetEnvironment(macCatalyst)
        AppDelegate.usingJitHacks = settingsAllowJit
#else
        if settingsAllowJit {
            // If possible, attempt to enable JIT for this process.
            AppDelegate.usingJitHacks = set_up_jit()
        }
#endif

        // If we attempted a boot, but did not finish one, something went wrong last time.
        // Force a recovery boot.
        if UserDefaults.standard.bool(forKey: "attempting_boot") {
            AppDelegate.forceRecoveryBoot = true
        }

        // Mark ourselves as attempting a boot.
        UserDefaults.standard.set(true, forKey: "attempting_boot")
        
        // To minimize startup time, start our kernel before anything else.
        qemu = QEMUInterface()
        qemu!.startQemuThread(forceRecoveryBoot: AppDelegate.forceRecoveryBoot)
        AppDelegate.isFirstBoot = qemu!.isFirstBoot()
        AppDelegate.memoryValueChanged = qemu!.memoryValueChanged()

        // Finally, before starting, spawn our background configuration server.
        configServer = ConfigServer(qemuInterface: qemu!, listenImmediately: true)

        return true
    }

    
    func applicationDidEnterBackground(_ application: UIApplication) {
        if (saving) {
            return;
        }

        if backgroundToPip() {
            NSLog("-----SWITCHED TO PIP-----")
            return();
        }

        saving = true
        let taskIdentifier = application.beginBackgroundTask {}
        qemu?.performBackgroundSave()
        application.endBackgroundTask(taskIdentifier)
        saving = false


        NSLog("-----BACKGROUNDED-----")
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
        NSLog("-----LOCKED-----")
        qemu?.stopHostChannels()
        configServer?.stop()
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        NSLog("-----UNLOCKED-----")
        NSLog("reconnecting SSH channels...")
        configServer?.listen()
        qemu?.startHostChannels()
        ViewController.getCurrentTerminal()?.forceReconnect()
    }


}

