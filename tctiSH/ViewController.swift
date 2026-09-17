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

        }

        // A code cache change costs nothing at the guest's end so this says what changed without
        // promising a slow boot the way the branches above have to.
        else if AppDelegate.codeCacheChanged {
            tv.feed(text: "The code cache size has changed.\r\n")
            tv.feed(text: "tctiSH is now using \(CodeCache.summary).\r\n\r\n")

            for _ in 0...20 {
                tv.feed(text: "\n")
            }

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

        // Before `becomeFirstResponder`, because the accessory view is read as the terminal takes
        // the keyboard. Installing it afterwards would need an explicit `reloadInputViews()` and
        // would briefly show the bar without it.
        SettingsAccessory.install(on: currentTerminal) { [weak self] in
            guard let self else { return }
            SettingsViewController.present(from: self)
        }

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
        observeCodeCache()

        // Every moment someone could be told. Becoming active covers a launch that follows the
        // failed save and a return from the backgrounding that caused it, including the first
        // activation of this launch.
        //
        // `didBecomeActive` rather than `willEnterForeground`, because showing this news spends it:
        // the flag is the only copy, and a pill raised before the app is really in front of someone
        // would run its few seconds out unwatched.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reportFailedSaveIfNeeded()
        }

        // And a save that fails while the app is already in front of someone, which neither of
        // those covers: coming back mid-save defers the reconnect and leaves the save running, so
        // its failure arrives with nobody about to become active for it.
        NotificationCenter.default.addObserver(
            forName: QEMUInterface.saveDidFail, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reportFailedSaveIfNeeded()
        }
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reconnectDeferred),
            name: AppDelegate.reconnectDeferred,
            object: nil)

        // Belt and braces: the observer goes on before anything could possibly have connected, but
        // a pill that never goes away is a worse bug than a pill that never appears.
        guard !terminal.connected else { return }

        showBootProgress(message: "Starting Linux")
        watchForMissingSnapshot()
    }

    @objc private func terminalDidConnect() {
        bootStallWatch?.cancel()
        bootStallWatch = nil
        stopWatchingForMissingSnapshot()
        status?.dismiss(key: Self.bootStatusKey)

        // Asked for here, and only here: there is now a session that would be lost if saving it
        // went wrong, which is the one thing this app ever posts a notification about. Asking at
        // launch would put the prompt in front of someone before the app had done anything.
        LocalAlert.requestPermission()
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

    /// Says why the shell hasn't come back yet.
    ///
    /// The same pill `terminalWillReconnect` uses, under the same key, so when
    /// the save finishes and the reconnect really starts this changes its
    /// message rather than stacking a second one beside it.
    @objc private func reconnectDeferred() {
        showBootProgress(message: "Finishing session save")
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

    /// Says so when the VM was told to resume from a snapshot that isn't there.
    ///
    /// Polled, because the answer isn't known until QEMU has opened the disk
    /// and looked: a second or two into a launch that has already started.
    private func watchForMissingSnapshot() {
        guard snapshotWatch == nil else { return }

        // QEMU settles this while it is opening the disk, a second or two in, so the answer is
        // either given early or not at all. The deadline is what stops a boot that never finishes
        // from leaving a timer asking the same question for the life of the app.
        let deadline = Date().addingTimeInterval(Self.snapshotWatchDeadline)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard qemu_snapshot_was_missing() else {
                if Date() >= deadline {
                    self?.stopWatchingForMissingSnapshot()
                }
                return
            }

            self?.stopWatchingForMissingSnapshot()

            // Disowned as well as reported. The pointer is this app's own bookkeeping and it is now
            // known to be wrong, so leaving it in place would mean saying this again on every
            // launch until a save happens to succeed.
            (UIApplication.shared.delegate as? AppDelegate)?.qemu?.forgetMissingResumeImage()

            self?.status?.present(
                .init(
                    key: Self.snapshotStatusKey,
                    message: "Snapshot not found",
                    state: .symbol("exclamationmark.triangle.fill"),
                    duration: 6,
                    tint: .systemOrange))
        }

        RunLoop.main.add(timer, forMode: .common)
        snapshotWatch = timer
    }

    private func stopWatchingForMissingSnapshot() {
        snapshotWatch?.invalidate()
        snapshotWatch = nil
    }

    /// Watches for a snapshot that never turned up.
    private var snapshotWatch: Timer?

    /// How long to keep asking whether the snapshot was there.
    ///
    /// Comfortably past the point where QEMU has opened the disk and decided,
    /// and well short of the boot-stall deadline, so a boot going wrong is
    /// reported as the one thing it is rather than as two.
    private static let snapshotWatchDeadline: TimeInterval = 20

    private static let snapshotStatusKey = "snapshot"

    // MARK: - Saving

    /// Says so when the last attempt to save the session failed.
    private func reportFailedSaveIfNeeded() {
        // Only when there is someone to tell. A failure can land while the app is in the
        // background, and putting the pill up there would let its few seconds expire on a screen
        // nobody is looking at, taking the flag with it.
        guard UIApplication.shared.applicationState == .active else { return }

        guard QEMUInterface.lastSaveFailed else { return }
        QEMUInterface.lastSaveFailed = false

        status?.present(
            .init(
                key: Self.saveStatusKey,
                message: "Couldn't save your session",
                state: .symbol("exclamationmark.triangle.fill"),
                duration: 6,
                tint: .systemOrange))
    }

    private static let saveStatusKey = "session-save"

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

    // MARK: - Code cache

    /// Follows the code cache, and offers to expand it when it fills up.
    ///
    /// Silent unless the cache was prepared in chunks, which only a blessed JIT
    /// launch running Dynamic ever is. Everywhere else there is nothing held
    /// back and nothing to offer.
    private func observeCodeCache() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(codeCacheStateChanged),
            name: CodeCacheMonitor.stateDidChange,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(codeCacheEventOccurred),
            name: CodeCacheMonitor.eventDidOccur,
            object: nil)

        CodeCacheMonitor.start()
    }

    /// Says what just happened to the cache, briefly.
    ///
    /// The notifications setting is applied at the source, in the monitor, so
    /// there is nothing to check here, but "gated" is not the same as "off":
    /// warnings come through whatever the setting says, which is why this picks
    /// them out below rather than treating everything alike.
    @objc private func codeCacheEventOccurred() {
        guard let event = CodeCacheMonitor.lastEvent else { return }

        // Warnings are picked out of the ordinary run of size changes, and given longer to be read:
        // the others are news about something working, where these ask you to decide whether to do
        // anything about it. Orange to match the other pill that reports a condition rather than
        // progress, which is "Snapshot not found".
        let warning = event.isWarning

        status?.present(
            .init(
                key: Self.codeCacheEventKey,
                message: event.message,
                state: .symbol(event.symbol),
                duration: warning ? 6 : 4,
                tint: warning ? .systemOrange : nil))
    }

    private static let codeCacheEventKey = "code-cache-event"

    @objc private func codeCacheStateChanged() {
        switch CodeCacheMonitor.state {
        case .quiet:
            stopCountdownTicks()
            status?.dismiss(key: Self.codeCacheStatusKey)

        case .countingDown, .growing:
            startCountdownTicks()
        }
    }

    /// Drives whichever ring the cache is currently showing.
    ///
    /// Redrawn rather than animated in one go. The countdown has to reach zero
    /// at the same moment the expansion starts, and the preparation ring is
    /// tracking an estimate that may be overtaken at any point. Neither
    /// survives being handed to a single animation and left alone.
    private func startCountdownTicks() {
        guard codeCacheTick == nil else {
            renderCodeCache()
            return
        }

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.renderCodeCache()
        }
        RunLoop.main.add(timer, forMode: .common)
        codeCacheTick = timer

        renderCodeCache()
    }

    private func renderCodeCache() {
        switch CodeCacheMonitor.state {
        case .quiet:
            stopCountdownTicks()

        case .countingDown(let next):
            let size = Mebibytes.describe(next / (1024 * 1024))

            status?.present(
                .init(
                    key: Self.codeCacheStatusKey,
                    message: "Code cache \u{2192} \(size)",
                    state: .countdown(CodeCacheMonitor.countdownRemaining),
                    duration: nil,
                    animated: false,
                    onTap: { CodeCacheMonitor.cancelGrowth() },
                    onSwipeAway: { CodeCacheMonitor.cancelGrowth() }))

        case .growing:
            // Finding and arming a debugger takes several seconds during which the app is perfectly
            // responsive, and saying nothing about it made the whole expansion read as one long
            // hang. `.quiet` is what ends the ticking.
            guard let progress = CodeCacheMonitor.preparationProgress else {
                status?.present(
                    .init(
                        key: Self.codeCacheStatusKey,
                        message: "Expanding",
                        state: .indeterminate,
                        duration: nil))
                return
            }

            status?.present(
                .init(
                    key: Self.codeCacheStatusKey,
                    message: JitEnablement.preparingMessage,
                    state: .progress(progress),
                    duration: nil,
                    animated: false))
        }
    }

    private func stopCountdownTicks() {
        codeCacheTick?.invalidate()
        codeCacheTick = nil
    }

    /// Redraws the countdown ring while one is running.
    private var codeCacheTick: Timer?

    private static let codeCacheStatusKey = "code-cache"

    /// Offers to import a pairing file, if one was all that JIT was missing.
    ///
    /// Call only once the view is on screen. `viewDidAppear` runs again after
    /// every dismissal so this also has to remember that it has already asked.
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
