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
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// Populated by UIKit from the scene's storyboard; we never touch it.
    var window: UIWindow?

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
