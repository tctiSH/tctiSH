//
//  AppStatus.swift
//  What the app as a whole has to say, in pills that every window shows, and
//  the questions it asks in the active window.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// Reports what concerns the whole app rather than one window: Linux starting,
/// the JIT verdict, the backend, the code cache, saves, disk compaction, quick
/// actions and pairing. Main thread only.
///
/// Its pills show in every window. Each window's `StatusPresenter` attaches
/// here as the window opens, and is given the pills already up as well as those
/// that come later. Swiping a pill away in any window takes it away in all of
/// them. A question, such as an alert, is asked once, in the window
/// `ViewController.active` gives.
final class AppStatus: NSObject {

    static let shared = AppStatus()

    private override init() {
        super.init()
    }

    // MARK: - Pills

    /// A pill that is up, and when it goes by itself, if it does.
    private struct Shown {
        var item: StatusPresenter.Item
        var expiry: Date?
    }

    /// The pills up, in the order they were first presented, which is the order
    /// they stack in.
    private var shown: [Shown] = []

    /// When each pill with a duration is dropped from `shown`. Each window's
    /// presenter drops its copy at the same time.
    private var expiries: [String: DispatchWorkItem] = [:]

    /// The windows' presenters.
    private var presenters: [Weak<StatusPresenter>] = []

    /// Whether `start()` has run.
    private var started = false

    /// Shows the pills in a window's presenter, those already up included. The
    /// first presenter to attach starts the app's reporting.
    func attach(_ presenter: StatusPresenter) {
        presenters.removeAll { $0.value == nil || $0.value === presenter }
        presenters.append(Weak(presenter))

        // Not one about to go, which would only flash up.
        for entry in shown where (entry.expiry?.timeIntervalSinceNow ?? .infinity) > 0.1 {
            var item = entry.item
            item.duration = entry.expiry.map { max($0.timeIntervalSinceNow, 0) }
            presenter.present(mirrored(item))
        }

        if !started {
            started = true
            start()
        }
    }

    /// Adds a pill in every window, or updates the one already under its key.
    func present(_ item: StatusPresenter.Item) {
        expiries.removeValue(forKey: item.key)?.cancel()
        let expiry = item.duration.map { Date().addingTimeInterval($0) }
        if let index = shown.firstIndex(where: { $0.item.key == item.key }) {
            shown[index] = Shown(item: item, expiry: expiry)
        } else {
            shown.append(Shown(item: item, expiry: expiry))
        }

        if let duration = item.duration {
            let work = DispatchWorkItem { [weak self] in self?.forget(key: item.key) }
            expiries[item.key] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }

        for presenter in presenters.compactMap(\.value) {
            presenter.present(mirrored(item))
        }
    }

    /// Takes a pill away in every window.
    func dismiss(key: String) {
        forget(key: key)
        for presenter in presenters.compactMap(\.value) {
            presenter.dismiss(key: key)
        }
    }

    private func forget(key: String) {
        expiries.removeValue(forKey: key)?.cancel()
        shown.removeAll { $0.item.key == key }
    }

    /// `item` as a window shows it: swiping it away there takes it away in the
    /// other windows too.
    private func mirrored(_ item: StatusPresenter.Item) -> StatusPresenter.Item {
        var mirrored = item
        mirrored.onSwipeAway = { [weak self] in
            self?.dismiss(key: item.key)
            item.onSwipeAway?()
        }
        return mirrored
    }

    // MARK: - Starting

    /// Starts reporting, once the first window has a presenter to report in.
    private func start() {
        // Held back while Settings First keeps the boot waiting, since what it says can change in
        // there; see `AppDelegate.releaseBootHeldForSettings`.
        if !AppDelegate.bootHeldForSettings {
            showBootMessage()
        }

        guardMonitorCommands()

        // Connect to the serial port and the user's monitor, which say something as soon as QEMU
        // starts, and ask whether Linux is up. The consoles connect themselves once QEMU has
        // started.
        ChardevTransport.kernelLog.start()
        ChardevTransport.vmManagement.start()
        GuestAgent.shared.start()
        GuestClock.shared.start()

        // These stack rather than take turns, so both are on screen together. Order here is
        // stacking order: the JIT verdict on top, where it reads first and then leaves after a few
        // seconds, and the boot spinner under it for as long as the VM takes -- so there's never a
        // moment with nothing on screen, which is what made an ordinary wait read as a hang.
        observeJitState()
        reportBootProgress()
        observeJitPreparation()
        observeCodeCache()
        observeBackend()
        observeCompaction()
        observeQuickActions()
        observeGuestZone()
        observeGuestSnapshotLoads()

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
        // those covers: coming back mid-save leaves the save running, so its failure arrives with
        // nobody about to become active for it.
        NotificationCenter.default.addObserver(
            forName: QEMUInterface.saveDidFail, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reportFailedSaveIfNeeded()
        }
    }

    /// Called each time a window appears, since an alert can be presented only
    /// from a view in a window.
    func windowDidAppear() {
        offerPairingFileIfWanted()
    }

    /// The pairing session in progress, if any. Strong: nothing else holds it.
    private var pairingSession: PairableHostPairing?

    /// Whichever pairing alert is up, so it can be replaced or taken away.
    private weak var pairingAlertOnScreen: UIAlertController?

    private static let pairingStatusKey = "pairing"
    private static let monitorGuardStatusKey = "monitor-guard"

    /// Whether the pairing-file alert has already been put up this launch.
    private var hasOfferedPairingFile = false

    /// Whether the JIT verdict has been logged and shown.
    private var hasReportedJitOutcome = false

    // MARK: - JIT status

    /// Says that the VM is still coming up, until it isn't.
    ///
    /// Booting takes long enough -- tens of seconds from cold -- to look like a
    /// hang, and the terminal stays empty throughout, so there is nothing else
    /// on screen saying the app is alive.
    ///
    /// Open-ended on purpose: there's no way to know how far along a boot is,
    /// so the dial spins rather than inventing a number.
    private func reportBootProgress() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(linuxDidComeUp),
            name: GuestAgent.linuxDidComeUp,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(returnedDuringSave),
            name: AppDelegate.returnedDuringSave,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(machineIsBack),
            name: AppDelegate.machineIsBack,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(unparkStarted),
            name: AppDelegate.unparkStarted,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(unparkDidFail),
            name: AppDelegate.unparkDidFail,
            object: nil)

        // Belt and braces: the observer goes on before Linux could possibly have answered, but a
        // pill that never goes away is a worse bug than a pill that never appears.
        guard !GuestAgent.shared.isUp else { return }

        showBootProgress(message: "Starting Linux")
        watchForMissingSnapshot()
    }

    @objc private func linuxDidComeUp() {
        dismissBootProgress()
        stopWatchingForMissingSnapshot()

        // Asked for here, and only here: there is now a session that would be lost if saving it
        // went wrong, which is the one thing this app ever posts a notification about. Asking at
        // launch would put the prompt in front of someone before the app had done anything.
        LocalAlert.requestPermission()

        // Needs a machine that has finished booting, and does nothing at all unless the QEMU
        // underneath the app has changed its migration format since the last run. Off the main
        // thread, because `delvm` is not instant on a snapshot worth a hundred megabytes.
        let qemu = (UIApplication.shared.delegate as? AppDelegate)?.qemu
        DispatchQueue.global(qos: .utility).async {
            qemu?.discardPreUpgradeSnapshots()
        }

        // Linux is up, so it can be handed the vCPUs wanted now.
        Vcpus.linuxIsUp()
    }

    /// Says why the terminal isn't answering yet: the machine is stopped until
    /// the save finishes.
    ///
    /// Shares the boot pill's key, so it inherits the stall watch: a save that
    /// never finishes is as much of a dead end as a boot that never finishes,
    /// and offers the same way out.
    @objc private func returnedDuringSave() {
        showBootProgress(message: "Finishing session save")
    }

    /// The machine is running again, after a save or a park that the app came
    /// back during.
    @objc private func machineIsBack() {
        dismissBootProgress()
    }

    private func dismissBootProgress() {
        bootStallWatch?.cancel()
        bootStallWatch = nil
        dismiss(key: Self.bootStatusKey)
    }

    /// Says why the terminal isn't answering yet when the memory was given back
    /// in the background and the session is being read back in.
    @objc private func unparkStarted() {
        // A return that tries again by itself makes the question moot, and answering it afterwards
        // would act on a machine that is no longer parked.
        unparkAlert?.dismiss(animated: true)
        unparkAlert = nil

        showBootProgress(message: "Restoring session")
    }

    /// The question `unparkDidFail` is asking, while it's up.
    private weak var unparkAlert: UIAlertController?

    /// Asks what to do about a session that wouldn't come back.
    ///
    /// No cancel: the machine is parked and can't run until one of these
    /// happens, so there is nothing to go back to.
    @objc private func unparkDidFail() {
        // Asked once, however many times it fails before an answer.
        if let unparkAlert, !unparkAlert.isBeingDismissed {
            return
        }

        guard let presenter = ViewController.active?.topmost, !presenter.isBeingDismissed else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.unparkDidFail()
            }
            return
        }

        bootStallWatch?.cancel()
        bootStallWatch = nil
        dismiss(key: Self.bootStatusKey)

        let appDelegate = UIApplication.shared.delegate as? AppDelegate

        let alert = UIAlertController(
            title: "Couldn't restore your session",
            message: "tctiSH gave Linux's memory back to iOS while it was in the background, "
                + "and reading your session back in has failed. It is still saved: quitting "
                + "and reopening tctiSH tries again from the start. Starting Linux afresh "
                + "gets you a shell now, but anything in the session is lost.",
            preferredStyle: .alert)

        alert.addAction(
            UIAlertAction(title: "Try Again", style: .default) { _ in
                appDelegate?.recoverFromFailedUnpark(.retry)
            })

        alert.addAction(
            UIAlertAction(title: "Quit tctiSH", style: .default) { _ in
                appDelegate?.recoverFromFailedUnpark(.quit)
            })

        alert.addAction(
            UIAlertAction(title: "Start Linux Afresh", style: .destructive) { [weak self] _ in
                // Only if it was taken up, or the pill would wait on a boot nobody started.
                if appDelegate?.recoverFromFailedUnpark(.startAfresh) == true {
                    self?.showBootProgress(message: "Starting Linux")
                }
            })

        unparkAlert = alert
        presenter.present(alert, animated: true)
    }

    /// Puts the boot pill up as a spinner, and starts the clock on it.
    private func showBootProgress(message: String) {
        present(
            .init(
                key: Self.bootStatusKey,
                message: message,
                state: .indeterminate,
                duration: nil))

        bootStallCounted = 0
        bootStallLastTick = ProcessInfo.processInfo.systemUptime
        scheduleBootStallTick()
    }

    private func scheduleBootStallTick() {
        bootStallWatch?.cancel()

        let watch = DispatchWorkItem { [weak self] in self?.bootStallTicked() }
        bootStallWatch = watch
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bootStallTick, execute: watch)
    }

    /// Counts the time since the last tick toward the deadline, all but any of
    /// it spent frozen; see `bootStallDeadline`.
    private func bootStallTicked() {
        let now = ProcessInfo.processInfo.systemUptime
        bootStallCounted += min(now - bootStallLastTick, Self.bootStallTick * 2)
        bootStallLastTick = now

        guard bootStallCounted >= Self.bootStallDeadline else {
            scheduleBootStallTick()
            return
        }

        bootStallWatch = nil
        bootLooksStalled()
    }

    /// Turns the boot pill into something you can act on.
    ///
    /// A spinner that has been going for half a minute has stopped being
    /// information and started being scenery. The alternative to this was
    /// finding the setting for a recovery boot, which is a lot to ask of
    /// someone who has just been left looking at a blank terminal.
    private func bootLooksStalled() {
        Log.qemu.warn(
            "nothing back after \(Int(Self.bootStallDeadline))s; offering a recovery boot")

        present(
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

        ViewController.active?.present(alert, animated: true)
    }

    /// Starts Linux again from nothing, and waits for it as for a boot.
    func performRecoveryBoot() {
        let qemu = (UIApplication.shared.delegate as? AppDelegate)?.qemu

        guard qemu?.requestRecoveryBoot() == true else {
            // QEMU itself isn't answering, so there's nothing further to try from in here.
            // Relaunching will recovery-boot on its own.
            present(
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

    // MARK: - Quick actions

    private static let quickActionStatusKey = "quick-action"

    /// Listens for the quick actions that need somewhere to be shown.
    private func observeQuickActions() {
        NotificationCenter.default.addObserver(
            forName: QuickActions.didArrive, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showQuickActionArrival()
        }

        // It may well have arrived before reporting started, in which case the notification has
        // already been and gone with nothing listening for it.
        showQuickActionArrival()
    }

    private func showQuickActionArrival() {
        guard let arrival = QuickActions.takeArrival() else { return }

        switch arrival {
        case .alreadySatisfied(let message, let symbol):
            present(
                .init(
                    key: Self.quickActionStatusKey,
                    message: message,
                    state: .symbol(symbol),
                    duration: 4))

        case .offersSwitch(let message, let kind):
            // Open-ended, because this is a question rather than news: it waits either for the tap
            // that answers it or for the swipe that declines it.
            present(
                .init(
                    key: Self.quickActionStatusKey,
                    message: message,
                    state: .symbol(kind == .native ? "hare.fill" : "tortoise.fill"),
                    duration: nil,
                    onTap: { [weak self] in
                        self?.dismiss(key: Self.quickActionStatusKey)
                        Backend.switchTo(kind, asked: true)
                    }))

        case .recoverInPlace:
            // The one action a running VM can honor by itself, so it is simply done. Resetting the
            // machine is exactly what a recovery boot is; going out through the home screen for it
            // would cost a relaunch and buy nothing.
            dismiss(key: Self.quickActionStatusKey)
            performRecoveryBoot()

        case .openSettings:
            ViewController.active?.openSettings(nil)
        }
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

            // Disowned as well as reported. The pointer is this app's bookkeeping and it is now
            // known to be wrong, so leaving it in place would mean saying this again on every
            // launch until a save happens to succeed.
            (UIApplication.shared.delegate as? AppDelegate)?.qemu?.forgetMissingResumeImage()

            self?.present(
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

        present(
            .init(
                key: Self.saveStatusKey,
                message: "Couldn't save your session",
                state: .symbol("exclamationmark.triangle.fill"),
                duration: 6,
                tint: .systemOrange))
    }

    private static let saveStatusKey = "session-save"

    /// Says when Linux changes time zone to follow the device, because programs
    /// already running keep the old one until restarted.
    private func observeGuestZone() {
        NotificationCenter.default.addObserver(
            forName: GuestClock.zoneDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let zone = notification.object as? String else { return }

            self?.present(
                .init(
                    key: Self.zoneStatusKey,
                    message: "Now on \(zone) time; restart programs to follow",
                    state: .symbol("clock.fill"),
                    duration: 6))
        }
    }

    private static let zoneStatusKey = "guest-zone"

    /// Says when `tctictl snapshot load` fails, which starts Linux afresh and
    /// loses the session.
    private func observeGuestSnapshotLoads() {
        NotificationCenter.default.addObserver(
            forName: QEMUInterface.guestSnapshotLoadFailed, object: nil, queue: .main
        ) { [weak self] notification in
            let tag = notification.object as? String ?? "the snapshot"

            self?.present(
                .init(
                    key: Self.guestSnapshotStatusKey,
                    message: "Couldn't load '\(tag)'; Linux is starting afresh",
                    state: .symbol("exclamationmark.triangle.fill"),
                    duration: 8,
                    tint: .systemOrange))
        }
    }

    private static let guestSnapshotStatusKey = "guest-snapshot"

    private static let bootStatusKey = "boot"

    /// How long a boot may take before we assume it isn't going to finish.
    ///
    /// A cold boot is advertised to the user as taking about twenty seconds, so
    /// this has to sit clear of that.
    private static let bootStallDeadline: TimeInterval = 30

    /// How often the watch counts. Any wait longer than this by more than
    /// `bootStallTick` again was spent frozen or suspended, and the rest of it
    /// isn't counted.
    private static let bootStallTick: TimeInterval = 1

    /// The watch's next count, so that it can be called off.
    private var bootStallWatch: DispatchWorkItem?

    /// How much of the deadline the boot has used so far, and when the watch
    /// last counted.
    private var bootStallCounted: TimeInterval = 0
    private var bootStallLastTick: TimeInterval = 0

    /// Follows JIT enablement, which can settle before reporting starts.
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

        // It may well have settled before reporting started, in which case the notification has
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
        case .blessed, .entitled:
            Log.jit.note("running with JIT")
        case .interpreted(let reason):
            Log.jit.note("running without JIT: \(reason.logDescription)")
        }

        present(
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

        // Preparation may well have started before reporting did.
        jitPreparationChanged()
    }

    @objc private func jitPreparationChanged() {
        switch JitEnablement.preparation {
        case .idle:
            break

        case .running(let message, let fraction):
            present(
                .init(
                    key: "prepare",
                    message: message,
                    state: fraction.map { .progress($0) } ?? .indeterminate,
                    duration: nil))

        case .finished(let succeeded, let message):
            // Held for a moment rather than vanishing the instant the work ends: whoever glanced
            // away would otherwise never learn how it went.
            present(
                .init(
                    key: "prepare",
                    message: message,
                    state: succeeded ? .succeeded : .failed,
                    duration: 3))
        }
    }

    // MARK: - Backend

    /// Follows the VM's backend: offers to switch, what a switch is doing, and
    /// what came of it.
    private func observeBackend() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(backendStateChanged),
            name: Backend.stateDidChange,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(backendEventOccurred),
            name: Backend.eventDidOccur,
            object: nil)

        backendStateChanged()
    }

    @objc private func backendStateChanged() {
        if let offer = Backend.offer {
            // A question, so it waits to be answered or declined.
            present(
                .init(
                    key: Self.backendOfferKey,
                    message: offer.message,
                    state: .symbol(offer.symbol),
                    duration: nil,
                    onTap: { Backend.acceptOffer() },
                    onSwipeAway: { Backend.declineOffer() }))
        } else {
            dismiss(key: Self.backendOfferKey)
        }

        switch Backend.activity {
        case .idle:
            dismiss(key: Self.backendActivityKey)

        case .preparing:
            // Finding and arming a debugger takes seconds during which the app is responsive. The
            // freeze that follows has the banner.
            present(
                .init(
                    key: Self.backendActivityKey,
                    message: JitEnablement.preparingMessage,
                    state: .indeterminate,
                    duration: nil))

        case .switching(let kind):
            present(
                .init(
                    key: Self.backendActivityKey,
                    message: "Switching to \(kind.name)…",
                    state: .indeterminate,
                    duration: nil))
        }
    }

    @objc private func backendEventOccurred() {
        guard let event = Backend.lastEvent else { return }
        let warning = event.isWarning

        present(
            .init(
                key: Self.backendEventKey,
                message: event.message,
                state: .symbol(event.symbol),
                duration: warning ? 6 : 4,
                tint: warning ? .systemOrange : nil))
    }

    private static let backendOfferKey = "backend-offer"
    private static let backendActivityKey = "backend-activity"
    private static let backendEventKey = "backend-event"

    // MARK: - Disk compaction

    /// Shows a disk compaction's progress in a pill while Settings is closed,
    /// since otherwise only its Storage row does, and it can be started from
    /// the Machine menu. Tapping the pill opens Settings there. The alert at
    /// the end says what came of it.
    private func observeCompaction() {
        let names = [
            DiskCompaction.stateDidChange, SettingsViewController.willOpen,
            SettingsViewController.didClose,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                self, selector: #selector(compactionChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func compactionChanged(_ notification: Notification) {
        // Settings may still be on its way in or out as it says so.
        let settingsOpen =
            notification.name == SettingsViewController.willOpen
            || (notification.name != SettingsViewController.didClose
                && SettingsViewController.isOpen)

        guard case .running(let fraction) = DiskCompaction.state, !settingsOpen else {
            dismiss(key: Self.compactionKey)
            return
        }

        present(
            .init(
                key: Self.compactionKey,
                message: "Compacting disk…",
                state: fraction.map { .progress($0) } ?? .indeterminate,
                duration: nil,
                onTap: {
                    guard let root = ViewController.active, root.presentedViewController == nil
                    else { return }
                    SettingsViewController.present(from: root, showing: .storage)
                }))
    }

    private static let compactionKey = "disk-compaction"

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

        present(
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
            dismiss(key: Self.codeCacheStatusKey)

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

            present(
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
                present(
                    .init(
                        key: Self.codeCacheStatusKey,
                        message: "Expanding",
                        state: .indeterminate,
                        duration: nil))
                return
            }

            present(
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
    /// Asked from the active window, once it is on screen. A window appears
    /// again after every dismissal, so this also has to remember that it has
    /// already asked.
    private func offerPairingFileIfWanted() {
        // Called on the JIT verdict as well as as a window appears, and the verdict can arrive
        // before there is a window to present from. Defer to whichever call has one rather than
        // failing silently.
        guard let root = ViewController.active, root.view.window != nil else { return }

        guard JitEnablement.needsPairingFile, !hasOfferedPairingFile else { return }
        hasOfferedPairingFile = true

        let alert = UIAlertController(
            title: "Enable JIT?",
            message: "tctiSH can run much faster with a debugger's help, but it "
                + "needs a pairing file for this device. Setting one up now "
                + "will speed up the next launch.",
            preferredStyle: .alert)

        // iOS 27 is where a device gained the ability to pair *with* a host.
        if #available(iOS 27.0, *) {
            alert.addAction(
                // Deliberately the same words the device shows in Settings: the user taps "Pair
                // with tctiSH" here and then goes looking for "Pair with tctiSH" there.
                UIAlertAction(title: "Pair with tctiSH", style: .default) { _ in
                    self.startPairing()
                })
        }

        alert.addAction(
            UIAlertAction(title: "Choose File", style: .default) { _ in
                // `importInteractively()` blocks until the user picks, so it cannot run on the main
                // thread as the picker it waits on is presented from there.
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = JitPairingFile.importInteractively()

                    DispatchQueue.main.async {
                        switch result {
                        case .imported:
                            // Preparation starts and puts up a pill within the second.
                            JitEnablement.pairingFileArrived()

                        case .cancelled:
                            // Asking again this launch would just be nagging; the next one will
                            // offer.
                            break

                        case .failed:
                            self.present(
                                .init(
                                    key: Self.pairingStatusKey,
                                    message: "Couldn't read that file",
                                    state: .symbol("exclamationmark.triangle.fill"),
                                    duration: 5))
                        }
                    }
                }
            })

        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))

        root.present(alert, animated: true)
    }

    /// Advertises tctiSH and waits for this device to pair with it.
    ///
    /// Held as a property because the wait outlives the call: the user leaves
    /// for Settings, and the advertisement has to still be up when they get
    /// there.
    private func startPairing() {
        let session = PairableHostPairing(
            onPIN: { [weak self] pin in self?.showPairingCode(pin) },
            onOutcome: { [weak self] outcome in self?.finishPairing(outcome) })

        pairingSession = session
        showPairingInstructions()
        session.start()
    }

    /// Tells the user where to go, because they cannot guess it.
    ///
    /// An alert rather than a pill as this is a path through Settings, it has
    /// to survive being read twice, and it has to still be there when they come
    /// back from looking. It is replaced by the code alert once the device
    /// connects.
    private func showPairingInstructions() {
        // Developer Mode is not worth checking for: since iOS 16 a development-signed app carrying
        // `get-task-allow` cannot launch without it, tctiSH claims that entitlement for JIT, and
        // the deployment target is 18.
        let alert = pairingAlert(
            title: "Pair with tctiSH",
            message: "On this device, open:\n\n"
                + "Settings › Privacy & Security › Developer Mode\n\n"
                + "Scroll down, tap \"Pair with tctiSH\", then come back here for the code.")

        alert.addAction(
            UIAlertAction(title: "Open Settings", style: .default) { _ in
                Self.openSettings()
            })

        showPairingAlert(alert)
    }

    /// Shows the code the user has to type into the device.
    ///
    /// An alert rather than a pill: this is the one moment in the flow where
    /// the user has something to read off and copy, and it should not be
    /// dismissed by accident while they are typing.
    private func showPairingCode(_ code: String) {
        showPairingAlert(
            pairingAlert(
                title: "Pairing Code",
                message: "Enter this code on your device to finish pairing:\n\n\(code)"))
    }

    /// Opens Settings where the user actually needs to be.
    private static func openSettings() {
        let application = UIApplication.shared

        func openOwnPage() {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            application.open(url)
        }

        guard let root = URL(string: "App-Prefs:") else {
            openOwnPage()
            return
        }

        application.open(root) { opened in
            Log.ui.note("settings: App-Prefs: \(opened ? "opened" : "was refused")")
            if !opened { openOwnPage() }
        }
    }

    /// Makes a pairing alert, with a Cancel that ends the pairing session.
    private func pairingAlert(title: String, message: String) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.pairingSession?.cancel()
            })
        return alert
    }

    /// Shows `alert`, taking away the previous one first.
    ///
    /// Recorded as the one on screen *now*: the outcome can land while a
    /// dismissal is still running, and `finishPairing` has to be able to take
    /// away an alert that has not finished appearing. It does that by clearing
    /// the property, which this then reads as "no longer wanted" and declines
    /// to present.
    private func showPairingAlert(_ alert: UIAlertController) {
        let previous = pairingAlertOnScreen
        pairingAlertOnScreen = alert

        let show = { [weak self] in
            guard self?.pairingAlertOnScreen === alert else { return }
            ViewController.active?.present(alert, animated: true)
        }

        if let previous {
            previous.dismiss(animated: false, completion: show)
        } else {
            show()
        }
    }

    private func finishPairing(_ outcome: PairableHostPairing.Outcome) {
        pairingSession = nil
        pairingAlertOnScreen?.dismiss(animated: true)
        pairingAlertOnScreen = nil

        switch outcome {
        case .paired(let pairingData):
            do {
                try JitPairingFile.store(pairingData)
                JitEnablement.pairingFileArrived()
            } catch {
                showPairingFailure(error.localizedDescription)
            }

        case .cancelled:
            // Their decision, and the alert is already gone. No comment.
            break

        case .failed(let reason):
            showPairingFailure(reason)
        }
    }

    private func showPairingFailure(_ reason: String) {
        present(
            .init(
                key: Self.pairingStatusKey,
                message: "Couldn't pair: \(reason)",
                state: .symbol("exclamationmark.triangle.fill"),
                duration: 8))
    }

    // MARK: - Boot message

    /// What the terminal says before Linux starts. Called as the first window
    /// loads, or once settings close when Settings First held the boot.
    func showBootMessage() {
        // If we're doing a recovery boot by user choice provide a message letting the user know
        // that this will take a moment.
        //
        // Ahead of the `forceRecoveryBoot` branch below, which would otherwise catch the quick
        // action and apologize for a resume that never went wrong.
        if QuickActions.request == .recovery
            || UserDefaults.standard.string(forKey: "resume_behavior") == "recovery_boot"
        {
            say("(Recovery booting; startup will take a bit.)")
        }

        // If this is our first boot, create the image we'll use for resuming.
        else if AppDelegate.isFirstBoot {
            say(
                "Welcome to tctiSH! This first boot will take just a bit longer, as we set up this "
                    + "environment for later use. Future boots will be way faster!",
                "This will take ~20 seconds or so.")
        }

        // If we're forcing a recovery boot by something other than user choice, provide a message
        // letting the user know
        else if AppDelegate.forceRecoveryBoot {
            say(
                "It seems like our last attempt at resuming might not have gone so well. We'll "
                    + "recover by restarting things the slow way.",
                "This will take ~20 seconds or so.")
        }

        // An updated app can mean an updated guest kernel, an updated QEMU, or a different machine
        // shape while a snapshot is a whole machine, including a kernel already running in its RAM.
        // None of those can be resumed into. Says "updated" rather than naming which, because the
        // distinction is ours and not the user's.
        else if AppDelegate.snapshotEpochChanged {
            say(
                "tctiSH has been updated, so we'll need to re-create our 'instant boot' "
                    + "environment, just this once after the update.",
                "This will take ~20 seconds or so.")
        }

        // If the user has just changed the amount of memory in the VM, they'll need a full boot to
        // re-populate the environment. Let them know.
        else if AppDelegate.memoryValueChanged {
            say(
                "The memory limit placed on tctiSH has changed. We'll need to re-create our "
                    + "'instant boot' environment, just this once after the change.",
                "This will take ~20 seconds or so.")
        }

        // A code cache change costs nothing at the guest's end so this says what changed without
        // promising a slow boot the way the branches above have to.
        else if AppDelegate.codeCacheChanged {
            say("The code cache size has changed. tctiSH is now using \(CodeCache.summary).")
        }
    }

    /// Prints paragraphs, each followed by a blank line, wrapped at word
    /// boundaries to the terminal's width.
    ///
    /// Written as whole paragraphs rather than broken by hand at some fixed
    /// width, which left a short line on an iPad's wide terminal running over
    /// three. Wrapped here rather than by the terminal, which would break the
    /// line in the middle of a word.
    private func say(_ paragraphs: String...) {
        // These messages are about Linux starting, so they go on `hvc0`'s TTY while it's open, and
        // on the active window's selected TTY otherwise.
        guard let tv = TTYs.shared.hvc0?.view ?? ViewController.active?.terminal else { return }
        let width = max(20, tv.getTerminal().cols)

        for paragraph in paragraphs {
            var line = ""
            for word in paragraph.split(separator: " ") {
                if !line.isEmpty, line.count + 1 + word.count > width {
                    tv.feed(text: line + "\r\n")
                    line = ""
                }
                line += line.isEmpty ? String(word) : " " + word
            }
            tv.feed(text: line + "\r\n\r\n")
        }
    }

    // MARK: - VM Management

    /// Has VM Management ask before submitting a command that would end,
    /// restart or rearrange the VM under the app; see `MonitorGuard`.
    private func guardMonitorCommands() {
        ChardevTransport.vmManagement.confirm = { [weak self] risk, answer in
            guard let self else {
                answer(false)
                return
            }
            ask(about: risk, answer: answer)
        }
    }

    /// Asks about a monitor command, from whatever is on top, and answers
    /// exactly once. VM Management sends nothing until it has an answer, so one
    /// that can't be asked is answered no, and said so.
    private func ask(
        about risk: MonitorGuard.Risk, answer: @escaping (Bool) -> Void, attempt: Int = 0
    ) {
        // Not over something on its way out, or over another question, which is answered first.
        guard let presenter = ViewController.active?.topmost, !presenter.isBeingDismissed,
            !(presenter is UIAlertController)
        else {
            askAgain(about: risk, answer: answer, attempt: attempt)
            return
        }

        var answered = false
        let reply = { (submit: Bool) in
            guard !answered else { return }
            answered = true
            answer(submit)
        }
        let alert = UIAlertController(
            title: risk.title, message: risk.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in reply(false) })
        alert.addAction(UIAlertAction(title: risk.action, style: .destructive) { _ in reply(true) })
        presenter.present(alert, animated: true)

        // A presentation UIKit refuses only logs, so look.
        DispatchQueue.main.async { [weak self] in
            guard alert.presentingViewController == nil, !answered else { return }
            answered = true
            self?.askAgain(about: risk, answer: answer, attempt: attempt)
        }
    }

    private func askAgain(
        about risk: MonitorGuard.Risk, answer: @escaping (Bool) -> Void, attempt: Int
    ) {
        guard attempt < 20 else {
            Log.ui.warn("couldn't ask about a monitor command (\(risk.title)); not sending it")
            answer(false)
            present(
                .init(
                    key: Self.monitorGuardStatusKey,
                    message: "Not sent: tctiSH couldn't ask first",
                    state: .symbol("exclamationmark.triangle"),
                    duration: 4))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else {
                answer(false)
                return
            }
            ask(about: risk, answer: answer, attempt: attempt + 1)
        }
    }
}

/// Holds an object without keeping it alive.
private struct Weak<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
