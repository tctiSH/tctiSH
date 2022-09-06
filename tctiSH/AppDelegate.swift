//
//  AppDelegate.swift
//  Primary application OS-event handlers.
//
//  Copyright (c) 2022 Katherine Temkin <k@ktemkin.com>
//

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var qemu: QEMUInterface?

    // Global application state.
    // FIXME: move these to a nice, clean singleton
    static var forceRecoveryBoot = false
    static var usingJitHacks = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {


        // Register our default values; which will be used for any unset values.
        UserDefaults.standard.register(defaults: [
            "resume_behavior": "persistent_boot",
            "boot_snapshot": "",
            "disk_name": "disk",
            "font_size": 14,
            "theme": "solzarizedDark",
            "attempting_boot": false
        ])

#if !targetEnvironment(macCatalyst)
        // If possible, attempt to enable JIT for this process.
        AppDelegate.usingJitHacks = set_up_jit()
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
        
        return true
    }

    
    func applicationDidEnterBackground(_ application: UIApplication) {
        let taskIdentifier = application.beginBackgroundTask {}
        qemu?.performBackgroundSave()
        application.endBackgroundTask(taskIdentifier)
    }


}

