//
//  SceneDelegate.swift
//  Scene lifecycle glue, required by the iOS 26 SDK and later.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// Minimal scene delegate.
///
/// Apps built against the iOS 26 SDK or later must adopt the UIScene life cycle
/// or they refuse to launch. tctiSH is deliberately single-scene (as there is
/// one VM per process) so this exists only to receive the lifecycle callbacks
/// that UIKit no longer delivers to `UIApplicationDelegate`, and hands them
/// straight back to `AppDelegate` where the logic already lives.
///
/// Both directions matter. Backgrounding snapshots the VM; returning has to
/// rebuild the shell, because the SSH session does not survive being suspended.
///
/// It is also where the home screen's quick actions arrive, by either of the
/// two doors UIKit delivers them through.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// Populated by UIKit from the scene's storyboard; we never touch it.
    var window: UIWindow?

    /// Where a quick action lands when it launched the app.
    ///
    /// The boot waits on this callback rather than going at the end of
    /// `didFinishLaunchingWithOptions`, because under the scene life cycle this
    /// is the first place the shortcut item is reliably to be found. It has to
    /// be in hand before QEMU allocates its code buffer.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        appDelegate?.handleSceneWillConnect(shortcutItem: connectionOptions.shortcutItem)
    }

    /// Where a quick action lands when the app was already running.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        QuickActions.performWhileRunning(shortcutItem)
        completionHandler(true)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        appDelegate?.handleEnteredBackground()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        appDelegate?.handleWillEnterForeground()
    }

    private var appDelegate: AppDelegate? {
        UIApplication.shared.delegate as? AppDelegate
    }
}
