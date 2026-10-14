//
//  SceneDelegate.swift
//  Scene lifecycle glue, required by the iOS 26 SDK and later.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// The delegate of a window's scene.
///
/// Apps built against the iOS 26 SDK or later must adopt the UIScene life cycle
/// or they refuse to launch. Saving and restoring the VM follow the app rather
/// than any one scene, so `AppDelegate` sees to those itself. This gives the
/// window's view controller its TTYs, notes which window is active, and, as a
/// backstop, starts the boot as a window becomes active.
///
/// It is also where the home screen's quick actions arrive, by either of the
/// two doors UIKit delivers them through.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// Populated by UIKit from the scene's storyboard; we never set it.
    var window: UIWindow?

    /// Where a quick action lands when it launched the app.
    ///
    /// Under the scene lifecycle this is the first place the shortcut item is
    /// reliably found, and it has to be in hand before QEMU allocates its code
    /// buffer. The boot follows when the scene comes to the foreground, which
    /// on a launch the user asked for is straight after this.
    ///
    /// It is also where the scene's view controller is given the window of TTYs
    /// it shows, before its view loads: the window saved for the session, or a
    /// new one, holding the TTY that moved to it or else a new TTY; or, at the
    /// TTY limit, none, and the new window is turned away; see
    /// `refuseNewWindow`.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        let ttys = TTYs.shared
        let id = session.persistentIdentifier
        let open = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
        let moving = WindowScenes.tty(movingIn: connectionOptions.userActivities)
        if let ttyWindow = ttys.window(forSession: id, openSessions: open)
            ?? moving.flatMap({ ttys.newWindow(forSession: id, moving: $0) })
            ?? ttys.newWindow(forSession: id)
        {
            (window?.rootViewController as? ViewController)?.ttyWindow = ttyWindow
        } else {
            refuseNewWindow(session)
        }

        appDelegate?.handleSceneWillConnect(shortcutItem: connectionOptions.shortcutItem)
        Accent.apply()
    }

    /// Turns a new window away when no more TTYs can open: its session is
    /// destroyed at once, and the window most recently active comes forward
    /// instead, with the limit pill. It's the nearest thing to showing all of
    /// tctiSH's windows, which iOS offers no way to do.
    private func refuseNewWindow(_ session: UISceneSession) {
        Log.ui.note("windows: new window refused; at the TTY limit")

        // Blank rather than a terminal view controller, which would have no TTYs to show.
        let blank = UIViewController()
        blank.view.backgroundColor = .black
        window?.rootViewController = blank

        let application = UIApplication.shared
        application.requestSceneSessionDestruction(session, options: nil) { error in
            Log.ui.warn("windows: couldn't close the refused window: \(error)")
        }
        let previous =
            ViewController.active?.view.window?.windowScene?.session
            ?? application.openSessions.first { other in
                TTYs.shared.windows.contains { $0.id == other.persistentIdentifier }
            }
        if let previous {
            WindowScenes.activate(previous)
        }
        AppStatus.shared.present(TTYs.limitPill)
    }

    /// Where a quick action lands when the scene was already connected: usually
    /// onto a running machine, but possibly onto one whose boot is still
    /// waiting for the scene to come to the front.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        appDelegate?.handleQuickAction(shortcutItem)
        completionHandler(true)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Again here, in case the storyboard's window wasn't in place yet when the scene connected.
        Accent.apply()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if let controller = window?.rootViewController as? ViewController {
            ViewController.active = controller
        }
        appDelegate?.handleSceneInForeground()
        ScreenAwake.apply()
    }

    private var appDelegate: AppDelegate? {
        UIApplication.shared.delegate as? AppDelegate
    }
}

/// The scene sessions behind the windows.
enum WindowScenes {

    /// Whether tctiSH can have more than one window: on iPad.
    static var areAvailable: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && UIApplication.shared.supportsMultipleScenes
    }

    /// The type of the activity that opens a window for a TTY to move to, which
    /// Info.plist lists. Its `userInfo` holds the TTY's ID.
    private static let ttyActivityType = "io.ara.tctish.tty"
    private static let ttyKey = "tty"

    /// The activity that opens a window for `tty` to move to, as a menu asks,
    /// or as a card dragged out of the switcher carries.
    static func activity(moving tty: TTY) -> NSUserActivity {
        let activity = NSUserActivity(activityType: ttyActivityType)
        activity.title = tty.name
        activity.userInfo = [ttyKey: tty.id.uuidString]
        return activity
    }

    /// The open TTY that one of `activities` asks to move to a new window, if
    /// any.
    static func tty(movingIn activities: Set<NSUserActivity>) -> TTY? {
        activities.lazy.filter { $0.activityType == ttyActivityType }
            .compactMap { ($0.userInfo?[ttyKey] as? String).flatMap(UUID.init(uuidString:)) }
            .compactMap(TTYs.shared.tty).first
    }

    /// Opens a new window, which makes a new TTY as its scene connects.
    static func openNewWindow() {
        let request = UISceneSessionActivationRequest(role: .windowApplication)
        UIApplication.shared.activateSceneSession(for: request) { error in
            Log.ui.warn("windows: couldn't open a new window: \(error)")
        }
    }

    /// Opens a new window, and moves `tty` to it as its scene connects.
    static func openWindow(moving tty: TTY) {
        let request = UISceneSessionActivationRequest(
            role: .windowApplication, userActivity: activity(moving: tty))
        UIApplication.shared.activateSceneSession(for: request) { error in
            Log.ui.warn("windows: couldn't open a window for \(tty.name): \(error)")
        }
    }

    /// Closes each saved window that no scene shows, as tctiSH comes to the
    /// foreground, since iOS doesn't always say when a window has closed.
    ///
    /// A window whose session iOS no longer has was closed while tctiSH wasn't
    /// running, and closes as Keep Programs Running When Closing a Window says.
    /// The rest close with their programs kept running, so that New Terminal
    /// brings them back on their consoles. They are windows closed from Show
    /// All Windows while tctiSH wasn't in front, windows iOS didn't bring back
    /// after a relaunch, and windows iOS set aside in the background to save
    /// memory; tctiSH can't tell them apart. Their sessions stay, so a window
    /// iOS brings back opens anew, with a new TTY.
    static func closeUnshown() {
        let application = UIApplication.shared
        guard application.supportsMultipleScenes else { return }

        let open = Set(application.openSessions.map(\.persistentIdentifier))
        let shown = Set(application.connectedScenes.map(\.session.persistentIdentifier))
        for window in TTYs.shared.windows {
            guard let id = window.id, !shown.contains(id) else { continue }
            if open.contains(id) {
                Log.ui.note("windows: \(id) has no scene; closing it, keeping its programs")
                // Its session stays: iOS may only have set the window aside to save memory, and if
                // it brings it back, it opens as a new window.
                TTYs.shared.closeWindow(window, endingPrograms: false, keepingSession: true)
            } else {
                Log.ui.note("windows: \(id) was closed while tctiSH wasn't running")
                TTYs.shared.windowDiscarded(session: id)
            }
        }
    }

    /// Whether a scene shows `window`. One that none does closes as tctiSH next
    /// comes to the foreground, so it's no place to move a TTY to.
    static func shows(_ window: TTYWindow) -> Bool {
        guard let id = window.id else { return false }
        return UIApplication.shared.connectedScenes.contains {
            $0.session.persistentIdentifier == id
        }
    }

    /// Brings the window of `session` forward, connecting its scene if need be.
    static func activate(_ session: UISceneSession) {
        UIApplication.shared.activateSceneSession(
            for: UISceneSessionActivationRequest(session: session)
        ) { error in
            Log.ui.warn("windows: couldn't bring back \(session.persistentIdentifier): \(error)")
        }
    }

    /// Destroys the scene session of a window that has closed.
    static func destroySession(of window: TTYWindow) {
        guard
            let id = window.id,
            let session = UIApplication.shared.openSessions.first(where: {
                $0.persistentIdentifier == id
            })
        else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
            Log.ui.warn("windows: couldn't close \(id): \(error)")
        }
    }
}

/// The Keep Screen Awake setting: while it is on, the screen does not lock
/// while tctiSH is in front, so a long-running command is not interrupted by
/// the app going to the background. iOS only honors this for the foreground
/// app, so leaving tctiSH still lets the device lock as usual.
enum ScreenAwake {
    static func apply() {
        UIApplication.shared.isIdleTimerDisabled = AppSetting.keepScreenAwake.bool
    }
}
