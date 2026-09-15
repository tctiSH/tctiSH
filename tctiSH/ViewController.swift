//
//  tctiSH primary view controller.
//  Currently, primarily hosts our terminal.
//
//  Created by Miguel de Icaza on 3/19/19.
//  Modified for tctiSH by @ktemkin.
//
//  Copyright © 2022 Kate Temkin. All rights reserved.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import UIKit
import SwiftTerm

class ViewController: UIViewController {
    var tv: TerminalView!

    /// The padding used around the current view's frame.
    let padding: CGFloat = 7

    /// Controls the offset at which this window will render given the
    /// keyboard's presence.
    var keyboardDelta: CGFloat = 0

    /// Shows system status: how we're running and what's happening alongside.
    private var status: StatusPresenter?

    /// Whether the pairing-file alert has already been put up this launch.
    private var hasOfferedPairingFile = false

    /// Whether the JIT verdict has been logged and shown.
    private var hasReportedJitOutcome = false

    /// Stores the most recently used terminal; for singleton-style fetches.
    private static var currentTerminal: TctiTermView?

    /// Stores the most recently used terminal's view controller; for
    /// singleton-style fetches.
    private static var currentTerminalController: UIViewController?

    /// Fetches the most recently created TctiTermView. Call only from the
    /// primary UI thread.
    ///
    /// In normal operation; this should always be the only term persented to
    /// the user.
    public static func getCurrentTerminal() -> TctiTermView? {
        return currentTerminal
    }

    /// Fetches the root ViewController, which houses our TctiTermView. Call
    /// only from the primary UI thread.
    ///
    /// In normal operation; this should always be the only term persented to
    /// the user.
    public static func getCurrent() -> UIViewController? {
        return currentTerminalController
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Start up our terminal emulator, which will display our actual terminal.
        let currentTerminal = TctiTermView(frame: makeFrame(keyboardDelta: 0))

        tv = currentTerminal
        view.addSubview(currentTerminal)

        // Update our "most recent" singletons.
        ViewController.currentTerminal = currentTerminal
        ViewController.currentTerminalController = self

        // If we're doing a recovery boot by user choice, provide a message letting the user know
        // that this will take a hot moment.
        if UserDefaults.standard.string(forKey: "resume_behavior") == "recovery_boot" {
            currentTerminal.feed(text: "(Recovery booting; startup will take a bit.)\r\n\r\n")
        }

        // If this is our first boot, create the image we'll use for resuming.
        else if AppDelegate.isFirstBoot {
            tv.feed(text: "Welcome to tctiSH! This first boot will take\r\n")
            tv.feed(text: "just a bit longer, as we set up this environment\r\n")
            tv.feed(text: "for later use. Future boots will be way faster!\r\n\r\n")

            tv.feed(text: "This will take ~20 seconds or so.\r\n\r\n")
        }

        // If we're forcing a recovery boot by something other than user choice, provide a message
        // letting the user know
        else if AppDelegate.forceRecoveryBoot {
            tv.feed(text: "It seems like our last attempt at resuming\r\n")
            tv.feed(text: "might not have gone so well. We'll recover\r\n")
            tv.feed(text: "by restarting things the slow way.\r\n\r\n")

            tv.feed(text: "This will take ~20 seconds or so.\r\n\r\n")
        }
        // If the user has just changed the amount of memory in the VM, they'll need a full boot to
        // re-populate the environment. Let them know.
        else if AppDelegate.memoryValueChanged {
            tv.feed(text: "The memory limit placed on tctiSH has changed.\r\n")
            tv.feed(text: "We'll need to re-create our 'instant boot'\r\n")
            tv.feed(text: "environment, just this once after the change.\r\n\r\n")

            tv.feed(text: "This will take ~20 seconds or so.\r\n\r\n")

        } else {
            // Provide some filler content,to ensure the ScrollView starts with something in it;
            // and then issue a "clear", so it's off the backlog. This is a cheap, hackish way of
            // getting there to be something in the UIScrollView buffer; which means that we avoid
            // the nasty "transparent" boxes it tries to squish at either end if there's not enough
            // content.
            //
            // We could squish in spacer controls; but these do the same thing and don't muck up the
            // position math SwiftTerm does later.
            for _ in 0...25 {
                tv.feed(text: "\n")
            }

        }

        setupKeyboardMonitor()
        currentTerminal.becomeFirstResponder()

        // All of these need a window, which is exactly why the launch path couldn't do them itself.
        status = StatusPresenter(over: view, backdrop: currentTerminal.nativeBackgroundColor)

        // These stack rather than take turns, so both are on screen together. Order here is
        // stacking order: the JIT verdict on top, where it reads first and then leaves after a few
        // seconds, and the boot spinner under it for as long as the VM takes -- so there's never a
        // moment with nothing on screen, which is what made an ordinary wait read as a hang.
        observeJitState()
        reportBootProgress(for: currentTerminal)
        observeJitPreparation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // The end of the black rectangle, as the user experiences it.
        Log.ui.note("launch: first frame at \(AppDelegate.sinceLaunch())")

        // Not in viewDidLoad. Presenting anything from there fails silently -- the view isn't in a
        // window yet, so there is nothing to present *from* -- and the symptom is simply that the
        // alert never appears.
        offerPairingFileIfWanted()
    }

    // MARK: - JIT status

    /// Says that the VM is still coming up, until it isn't.
    ///
    /// Booting takes long enough -- tens of seconds from cold -- to look like a
    /// hang, and the terminal stays empty throughout, so there is nothing else
    /// on screen saying the app is alive.
    ///
    /// Open-ended on purpose: there's no way to know how far along a boot is,
    /// so the dial spins rather than inventing a number.
    private func reportBootProgress(for terminal: TctiTermView) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalDidConnect),
            name: TctiTermView.didConnect,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalWillReconnect),
            name: TctiTermView.willReconnect,
            object: nil)

        // Belt and braces: the observer goes on before anything could possibly have connected, but
        // a pill that never goes away is a worse bug than a pill that never appears.
        guard !terminal.connected else { return }

        showBootProgress(message: "Starting Linux")
    }

    @objc private func terminalDidConnect() {
        bootStallWatch?.cancel()
        bootStallWatch = nil
        status?.dismiss(key: Self.bootStatusKey)
    }

    /// Says that the session is coming back, after a lock or a spell in the
    /// background.
    ///
    /// Shares the boot pill's key, so it inherits the stall watch: a resume
    /// that never finishes is as much of a dead end as a boot that never
    /// finishes, and offers the same way out.
    @objc private func terminalWillReconnect() {
        showBootProgress(message: "Resuming from snapshot")
    }

    /// Puts the boot pill up as a spinner, and starts the clock on it.
    private func showBootProgress(message: String) {
        status?.present(
            .init(
                key: Self.bootStatusKey,
                message: message,
                state: .indeterminate,
                duration: nil))

        bootStallWatch?.cancel()

        let watch = DispatchWorkItem { [weak self] in self?.bootLooksStalled() }
        bootStallWatch = watch
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bootStallDeadline, execute: watch)
    }

    /// Turns the boot pill into something you can act on.
    ///
    /// A spinner that has been going for half a minute has stopped being
    /// information and started being scenery. The alternative to this was
    /// finding the setting for a recovery boot, which is a lot to ask of
    /// someone who has just been left looking at a blank terminal.
    private func bootLooksStalled() {
        Log.qemu.warn("no shell after \(Int(Self.bootStallDeadline))s; offering a recovery boot")

        status?.present(
            .init(
                key: Self.bootStatusKey,
                message: "Tap to recover",
                state: .failed,
                duration: nil,
                tint: .systemRed,
                onTap: { [weak self] in self?.offerRecoveryBoot() }))
    }

    private func offerRecoveryBoot() {
        let alert = UIAlertController(
            title: "Recovery boot?",
            message: "Linux hasn't come up. A recovery boot starts it again from "
                + "scratch, which usually fixes it -- but anything in the "
                + "resumed session is lost.",
            preferredStyle: .alert)

        alert.addAction(
            UIAlertAction(title: "Yes", style: .destructive) { [weak self] _ in
                self?.performRecoveryBoot()
            })

        alert.addAction(UIAlertAction(title: "No", style: .cancel))

        present(alert, animated: true)
    }

    private func performRecoveryBoot() {
        let qemu = (UIApplication.shared.delegate as? AppDelegate)?.qemu

        guard qemu?.requestRecoveryBoot() == true else {
            // QEMU itself isn't answering, so there's nothing further to try from in here.
            // Relaunching will recovery-boot on its own.
            status?.present(
                .init(
                    key: Self.bootStatusKey,
                    message: "Reopen the app",
                    state: .failed,
                    duration: nil,
                    tint: .systemRed))
            return
        }

        // Back to waiting, with the clock restarted -- so a recovery boot that also stalls offers
        // itself again rather than hanging silently.
        showBootProgress(message: "Restarting Linux")
    }

    private static let bootStatusKey = "boot"

    /// How long a boot may take before we assume it isn't going to finish.
    ///
    /// A cold boot is advertised to the user as taking about twenty seconds, so
    /// this has to sit clear of that.
    ///
    /// Deliberately flat, blessing or not (Ara, 2026-09-14). Blessing finishes
    /// before the guest starts, so once it has returned the boot has had its
    /// thirty seconds like any other -- and stretching the deadline to cover
    /// work that has already finished just delays the offer of a way out.
    private static let bootStallDeadline: TimeInterval = 30

    /// Fires if the shell never arrives.
    private var bootStallWatch: DispatchWorkItem?

    /// Follows JIT enablement, which now outlives this view being created.
    ///
    /// Two separate things come out of it. While it is still going the banner
    /// is up, because the tail of enablement stops the process outright and a
    /// silent freeze reads as a crash. Once it has settled the verdict goes in
    /// a pill, which is worth knowing but not worth a permanent fixture.
    private func observeJitState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(jitStateChanged),
            name: JitEnablement.stateDidChange,
            object: nil)

        // It may well have settled before this view existed, in which case the notification has
        // already been and gone.
        jitStateChanged()
    }

    @objc private func jitStateChanged() {
        if let message = JitEnablement.bannerMessage {
            FreezeBanner.raise(message)
        } else {
            FreezeBanner.lower()
        }

        // Fires for every change, and the verdict only arrives once.
        guard let outcome = JitEnablement.outcome, !hasReportedJitOutcome else { return }
        hasReportedJitOutcome = true

        switch outcome {
        case .blessed, .ptrace:
            Log.jit.note("running with JIT")
        case .interpreted(let reason):
            Log.jit.note("running without JIT: \(reason.logDescription)")
        }

        status?.present(
            .init(
                key: "jit",
                message: outcome.status.message,
                state: .symbol(outcome.status.symbol),
                duration: 5))

        offerPairingFileIfWanted()
    }

    /// Shows and updates the progress pill as background preparation runs.
    private func observeJitPreparation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(jitPreparationChanged),
            name: JitEnablement.preparationDidChange,
            object: nil)

        // Preparation may well have started before this view existed.
        jitPreparationChanged()
    }

    @objc private func jitPreparationChanged() {
        switch JitEnablement.preparation {
        case .idle:
            break

        case .running(let message, let fraction):
            status?.present(
                .init(
                    key: "prepare",
                    message: message,
                    state: fraction.map { .progress($0) } ?? .indeterminate,
                    duration: nil))

        case .finished(let succeeded, let message):
            // Held for a moment rather than vanishing the instant the work ends: whoever glanced
            // away would otherwise never learn how it went.
            status?.present(
                .init(
                    key: "prepare",
                    message: message,
                    state: succeeded ? .succeeded : .failed,
                    duration: 3))
        }
    }

    /// Offers to import a pairing file, if one was all that JIT was missing.
    ///
    /// Call only once the view is on screen. `viewDidAppear` runs again after
    /// every dismissal -- returning from the document picker included -- so
    /// this also has to remember that it has already asked.
    private func offerPairingFileIfWanted() {
        // Called on the JIT verdict as well as from `viewDidAppear`, and the verdict can arrive
        // before there is a window to present from. Defer to whichever call has one rather than
        // failing silently.
        guard view.window != nil else { return }

        guard JitEnablement.needsPairingFile, !hasOfferedPairingFile else { return }
        hasOfferedPairingFile = true

        let alert = UIAlertController(
            title: "Enable JIT?",
            message: "tctiSH can run much faster with a debugger's help, but it "
                + "needs a pairing file for this device. Importing one now "
                + "will speed up the next launch.",
            preferredStyle: .alert)

        alert.addAction(
            UIAlertAction(title: "Choose File", style: .default) { _ in
                // `importInteractively()` blocks until the user picks, so it cannot run on the main
                // thread -- the picker it waits on is presented from there.
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = JitPairingFile.importInteractively()

                    DispatchQueue.main.async {
                        switch result {
                        case .imported:
                            // Says so itself: preparation starts and puts up its own pill within
                            // the second.
                            JitEnablement.pairingFileArrived()

                        case .cancelled:
                            // Deliberate, so no comment. Asking again this launch would just be
                            // nagging; the next one will offer.
                            break

                        case .failed:
                            self.status?.present(
                                .init(
                                    key: "pairing",
                                    message: "Couldn't read that file",
                                    state: .symbol("exclamationmark.triangle.fill"),
                                    duration: 5))
                        }
                    }
                }
            })

        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))

        present(alert, animated: true)
    }

    func makeFrame(keyboardDelta: CGFloat, _ fn: String = #function, _ ln: Int = #line) -> CGRect {
        return CGRect(
            x: view.safeAreaInsets.left + padding,
            y: view.safeAreaInsets.top + padding,
            width: view.frame.width - view.safeAreaInsets.left - view.safeAreaInsets.right
                - (padding * 2),
            height: view.frame.height - view.safeAreaInsets.top - keyboardDelta - (padding * 2))
    }

    func setupKeyboardMonitor() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIWindow.keyboardWillShowNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIWindow.keyboardWillHideNotification,
            object: nil)
    }

    @objc private func keyboardWillShow(_ notification: NSNotification) {
        guard
            let keyboardValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue
        else { return }

        let keyboardScreenEndFrame = keyboardValue.cgRectValue
        let keyboardViewEndFrame = view.convert(keyboardScreenEndFrame, from: view.window)
        keyboardDelta = keyboardViewEndFrame.height
        tv.frame = makeFrame(keyboardDelta: keyboardViewEndFrame.height)
    }

    override func viewWillTransition(
        to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator
    ) {
        tv.frame = CGRect(origin: tv.frame.origin, size: size)
    }

    @objc private func keyboardWillHide(_ notification: NSNotification) {
        keyboardDelta = 0
        tv.frame = makeFrame(keyboardDelta: 0)
    }

    override func viewWillLayoutSubviews() {
        tv.frame = makeFrame(keyboardDelta: keyboardDelta)
    }
}
