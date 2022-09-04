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
        
        // To minimize startup time, start our kernel before anything else.
        qemu = QEMUInterface()
        qemu!.startQemuThread()
        
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        let taskIdentifier = application.beginBackgroundTask {}
        qemu?.performBackgroundSave()
        application.endBackgroundTask(taskIdentifier)
    }

    /// Automatically save our VM state on exit.
    func applicationWillTerminate(_ application: UIApplication) {
    }
    
    

}

