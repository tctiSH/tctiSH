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
    

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Register our default values; which will be used for any unset values.
        UserDefaults.standard.register(defaults: [
            "resume_behavior": "persistent_boot",
            "boot_snapshot": "",
            "disk_name": "disk",
            "font_size": 14,
            "theme": "solzarizedDark"
        ])
        
        // To minimize startup time, start our kernel before anything else.
        qemu = QEMUInterface()
        qemu!.startQemuThread()
        
        return true
    }

    
    func applicationDidEnterBackground(_ application: UIApplication) {
        let taskIdentifier = application.beginBackgroundTask {}
        qemu?.performBackgroundSave()
        application.endBackgroundTask(taskIdentifier)
    }


}

