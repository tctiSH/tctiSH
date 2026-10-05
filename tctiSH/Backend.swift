//
//  Backend.swift
//  Which of QEMU's two backends the VM runs on, and moving it between them.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// How the user wants JIT handled: the Execution Mode setting.
enum ExecutionMode: String, CaseIterable {

    /// Waits for JIT at launch and switches to it by itself if it arrives
    /// later. Never leaves it for TCTI.
    case always = "always_jit"

    /// Starts under TCTI at once, and offers JIT once it can be had. Offers
    /// TCTI when the code cache wants to grow and no helper can be reached.
    case dynamicAsk = "dynamic_ask"

    /// As `dynamicAsk`, but switches in both directions without asking.
    case dynamicAuto = "dynamic_auto"

    /// TCTI only. JIT is never offered.
    case never = "never_jit"

    /// What the setting holds.
    static var setting: ExecutionMode {
        ExecutionMode(rawValue: AppSetting.jitMode.string) ?? .dynamicAuto
    }

    /// What this session follows: the setting, unless a quick action says
    /// something different.
    static var current: ExecutionMode {
        sessionOverride ?? setting
    }

    /// Set from a quick action at launch; cleared when the setting changes.
    static var sessionOverride: ExecutionMode?

    static func migrate() {
        if AppSetting.jitMode.string == "jit_when_possible" {
            AppSetting.jitMode.set(ExecutionMode.dynamicAuto.rawValue)
        }
    }

    /// Whether this mode switches to JIT without asking.
    var switchesToNativeAlone: Bool {
        self == .always || self == .dynamicAuto
    }
}

/// The VM's backend: TCTI, which needs no JIT, or native code, which does.
///
/// QEMU holds both and can move a running VM between them. Moving to native
/// code needs its code buffer prepared first, which under TXM means a debugger
/// and a freeze, exactly as growing the code cache does; moving to TCTI needs
/// nothing.
///
/// Main-thread state throughout; the work runs on `queue`.
enum Backend {

    enum Kind: Equatable {
        case tcti
        case native

        var name: String {
            switch self {
            case .tcti: return "TCTI"
            case .native: return "JIT"
            }
        }
    }

    // MARK: - What the UI sees

    /// Which backend the VM is on, or nil before QEMU is up.
    static var current: Kind? {
        switch qemu_backend_current() {
        case 1: return .tcti
        case 0: return .native
        default: return nil
        }
    }

    /// What is under way.
    enum Activity: Equatable {
        case idle

        /// Finding and arming a debugger, before the freeze.
        case preparing

        /// The switch itself, which is short.
        case switching(to: Kind)
    }

    private(set) static var activity: Activity = .idle

    /// A switch put to the user, waiting for a tap.
    enum Offer: Equatable {
        case toNative

        /// The code cache wants to grow and no helper can be reached to prepare
        /// more of native code's buffer; TCTI's is usable in full.
        case toTctiToGrow

        var message: String {
            switch self {
            case .toNative: return "Tap to switch to JIT"
            case .toTctiToGrow: return "Tap to keep growing with TCTI"
            }
        }

        var symbol: String {
            switch self {
            case .toNative: return "hare.fill"
            case .toTctiToGrow: return "tortoise.fill"
            }
        }
    }

    private(set) static var offer: Offer?

    /// Posted on the main queue when `activity` or `offer` changes.
    static let stateDidChange = Notification.Name("io.ara.tctish.backend.stateDidChange")

    /// Something that happened, for a pill.
    enum Event {
        case switched(to: Kind)
        case failed(String)

        var message: String {
            switch self {
            case .switched(let kind): return "Now running with \(kind.name)"
            case .failed(let reason): return reason
            }
        }

        var symbol: String {
            switch self {
            case .switched(.native): return "hare.fill"
            case .switched(.tcti): return "tortoise.fill"
            case .failed: return "xmark.circle.fill"
            }
        }

        var isWarning: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private(set) static var lastEvent: Event?

    /// Posted on the main queue when there is a `lastEvent` to show.
    static let eventDidOccur = Notification.Name("io.ara.tctish.backend.eventDidOccur")

    /// Whether native code's buffer is mapped and prepared, so that switching
    /// to it needs no debugger. Asked of QEMU, from any thread.
    ///
    /// Asked rather than tracked, because getting it wrong is not harmless:
    /// believing it unprepared when it is attaches a helper whose script then
    /// waits for a trap QEMU never raises, and hangs the helper.
    static var nativePrepared: Bool { qemu_backend_native_ready() }

    /// Whether a switch or a preparation is under way, for the code cache
    /// monitor, which must not grow the cache in the middle of one.
    static var isBusy: Bool { activity != .idle }

    // MARK: - Starting

    /// Begins watching for JIT. Main thread, once the VM has been started.
    static func booted() {
        startWatching()
    }

    /// Whether the VM is here to be switched: the app is in front, and the
    /// machine isn't being saved, parked or brought back from a park. A switch
    /// meanwhile would race the snapshot, or find the code cache handed back.
    private static var mayActNow: Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        return (UIApplication.shared.delegate as? AppDelegate)?.machineIsAway == false
    }

    // MARK: - Switching

    /// Switches the VM to `kind`. `asked` says the user asked for this one, so
    /// a failure is always reported; an automatic one reports only what the
    /// user needs to know. Main thread.
    static func switchTo(_ kind: Kind, asked: Bool) {
        guard activity == .idle else { return }
        guard let running = current else {
            if asked { report(.failed("The VM isn't running yet")) }
            return
        }
        guard running != kind else { return }

        guard mayActNow else {
            if asked {
                report(.failed("The session is being saved or restored; try again shortly"))
            }
            return
        }

        // An expansion would trap into a debugger with a switch half done.
        guard !CodeCacheMonitor.isGrowing else {
            if asked { report(.failed("The code cache is being expanded; try again shortly")) }
            return
        }

        // A choice the user made is not for the app to undo. Asked for TCTI, the session stays
        // there -- no switching back by itself, no offers -- until they ask for JIT or change
        // Execution Mode. Asked for JIT, that's over.
        if asked {
            heldOnTcti = kind == .tcti
        }

        withdrawOffer()
        CodeCacheMonitor.cancelPendingGrowth()
        Log.jit.note("backend: switching to \(kind.name)\(asked ? ", as asked" : "")")

        // Busy from now, not from when the queue gets to it: a second tap, an offer or a watch tick
        // arriving meanwhile must find a switch under way.
        publish(activity: kind == .native ? .preparing : .switching(to: .tcti))

        queue.async {
            let failure: String?
            switch kind {
            case .native: failure = switchToNative()
            case .tcti: failure = switchToTcti()
            }

            DispatchQueue.main.async {
                publish(activity: .idle)
                finishSwitch(to: kind, failure: failure, asked: asked)
            }
        }
    }

    /// Where the switches and preparations run, one at a time.
    private static let queue = DispatchQueue(label: "io.ara.tctish.backend", qos: .userInitiated)

    /// Returns why it failed, or nil if the VM is on native code now.
    private static func switchToNative() -> String? {
        if let failure = prepareNative() {
            return failure
        }

        publish(activity: .switching(to: .native))
        return requestSwitch(tcti: false)
    }

    /// Returns why it failed, or nil if the VM is on TCTI now.
    private static func switchToTcti() -> String? {
        publish(activity: .switching(to: .tcti))
        return requestSwitch(tcti: true)
    }

    /// Asks QEMU for the switch and waits for it to settle. Off the main
    /// thread.
    private static func requestSwitch(tcti: Bool) -> String? {
        let before = qemu_backend_switches()

        guard qemu_backend_switch(tcti) else {
            return "QEMU couldn't be asked to switch"
        }

        let deadline = Date().addingTimeInterval(switchDeadline)
        while qemu_backend_switches() == before {
            guard Date() < deadline else { return "The switch didn't happen in time" }
            Thread.sleep(forTimeInterval: 0.01)
        }

        let landed = qemu_backend_current() == (tcti ? 1 : 0)
        return landed ? nil : (lastQemuError() ?? "The switch didn't happen")
    }

    /// How long a switch may take to settle. Normally milliseconds: every vCPU
    /// stops between translated blocks and the translations are dropped.
    private static let switchDeadline: TimeInterval = 30

    private static func finishSwitch(to kind: Kind, failure: String?, asked: Bool) {
        guard let failure else {
            Log.jit.note("backend: now on \(kind.name)")
            failures = 0
            CodeCacheMonitor.backendChanged()
            report(.switched(to: kind))

            // Off native code: its buffer goes too, if the user would rather it did.
            if kind == .tcti && AppSetting.flushJitBuffers.bool {
                releaseNative()
            }
            return
        }

        Log.jit.warn("backend: couldn't switch to \(kind.name) -- \(failure)")
        failures += 1

        // The VM is where it was and carries on. Said out loud when it was asked for, and when the
        // user is otherwise left waiting for an offer or a switch that didn't come.
        if asked || ExecutionMode.current != .dynamicAuto || failures == 1 {
            report(.failed("Couldn't switch to \(kind.name): \(failure)"))
        }

        // Not again until something might have changed; see `conditionsMayHaveChanged`.
        waitingForChange = true
    }

    /// Failures in a row, so an automatic retry that keeps failing says so
    /// once.
    private static var failures = 0

    // MARK: - Preparing native code

    /// Maps and prepares native code's buffer, if it isn't already. Returns why
    /// it couldn't, or nil once it is. Off the main thread.
    private static func prepareNative() -> String? {
        if nativePrepared { return nil }

        #if targetEnvironment(macCatalyst)
            // Catalyst may map JIT memory by entitlement: nothing to arrange.
            return finishPreparing(debugger: false)
        #else
            switch TxmPresence.current {
            case .absent:
                // Pre-TXM: a process that believes it is being debugged may map executable memory,
                // which is what the ptrace hack arranges, now rather than at launch.
                guard jit_may_map_executable() || set_up_jit() else {
                    return "JIT was refused"
                }
                return finishPreparing(debugger: false)

            case .unknown:
                return "couldn't tell whether this device needs a debugger"

            case .present:
                return prepareUnderTxm()
            }
        #endif
    }

    /// Under TXM: a debugger, armed, then the trap that prepares the buffer.
    private static func prepareUnderTxm() -> String? {
        // Xcode, most likely, whose hook owns the trap and is long since armed; see
        // `JitEnablement.enableUnderTxm()`.
        if jit_debugger_tracing() {
            return finishPreparing(debugger: true)
        }

        guard let pairingData = JitPairingFile.read() else {
            return "no pairing file"
        }

        let started = Date()
        let declined = Latch()

        // Returns once QEMU has let the debugger go, which the preparation below does.
        JITHelperClient.enable(pairingData: pairingData, targetPID: getpid()) { reply in
            Log.jit.note("backend: helper returned \(reply?.detail ?? "nothing")")

            guard let reply, reply.outcome == .succeeded else {
                declined.close()

                // Much the commonest reason is a developer disk image that isn't mounted, which
                // takes a network and minutes. Started now, and the offer comes back once it's done
                // -- but not again once it has worked: a helper that declines for some other reason
                // would otherwise send this round again every time it finished.
                DispatchQueue.main.async {
                    switch JitEnablement.preparation {
                    case .running, .finished(true, _): return
                    case .idle, .finished(false, _): break
                    }
                    JitEnablement.prepareInBackground(pairingData: pairingData)
                }
                return
            }
        }

        guard waitForDebugger(unless: declined) else {
            return declined.isClosed ? "the JIT helper declined" : "no debugger attached"
        }

        Log.jit.note(
            String(format: "backend: debugger attached after %.2fs", -started.timeIntervalSinceNow))

        // P_TRACED is set before the script has armed its handler; see `CodeCacheMonitor`.
        Thread.sleep(forTimeInterval: settleBeforeTrap)
        return finishPreparing(debugger: true)
    }

    /// The preparation itself: under TXM, the freeze. Returns why it failed.
    private static func finishPreparing(debugger: Bool) -> String? {
        if debugger {
            FreezeBanner.raiseAndWait(JitEnablement.preparingMessage)
        }
        defer {
            if debugger { FreezeBanner.lower() }
        }

        let result = qemu_backend_prepare_native()
        guard result != 0 else {
            return lastQemuError() ?? "QEMU couldn't prepare native code"
        }

        Log.jit.note("backend: native code's buffer \(result == 1 ? "prepared" : "was ready")")
        return nil
    }

    /// Blocks until a debugger attaches, the helper gives up, or time runs out.
    private static func waitForDebugger(unless declined: Latch) -> Bool {
        let deadline = Date().addingTimeInterval(attachDeadline)

        while Date() < deadline {
            if jit_debugger_tracing() { return true }
            if declined.isClosed { return false }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return jit_debugger_tracing()
    }

    private static let attachDeadline: TimeInterval = 10
    private static let settleBeforeTrap: TimeInterval = 2

    /// A one-way flag, set on one thread and read on another.
    private final class Latch {
        private let lock = NSLock()
        private var closed = false

        var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            closed = true
        }
    }

    private static func lastQemuError() -> String? {
        guard let raw = qemu_backend_last_error() else { return nil }
        defer { free(raw) }
        return String(cString: raw)
    }

    // MARK: - Native code's buffer while on TCTI

    /// Gives native code's buffer back, if the VM is on TCTI: Flush JIT
    /// Buffers, or parking. Main thread; the work is quick and runs on `queue`.
    static func releaseNative() {
        guard nativePrepared, current == .tcti else { return }

        queue.async {
            let released = releaseNativeNow()
            if !released {
                DispatchQueue.main.async {
                    report(.failed("Couldn't release JIT buffers: \(lastQemuError() ?? "refused")"))
                }
            }
        }
    }

    /// The same, from a thread that can wait for it: the park, which runs off
    /// the main thread. Returns whether it was given back.
    @discardableResult
    static func releaseNativeNow() -> Bool {
        guard qemu_backend_current() == 1 else { return false }

        let released = qemu_backend_release_native()

        // For whatever shows the buffer's state.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: stateDidChange, object: nil)
        }

        if released {
            Log.jit.note("backend: native code's buffer given back while on TCTI")
        } else {
            Log.jit.warn("backend: native code's buffer kept -- \(lastQemuError() ?? "refused")")
        }
        return released
    }

    // MARK: - Watching for JIT

    private static var timer: Timer?

    /// Set after a failure: no further automatic attempts or offers until
    /// something has changed that might make the next one work.
    private static var waitingForChange = false

    /// Set when an offer is swiped away; cleared on return to the foreground.
    private static var offerDeclined = false

    /// Set when the user switched to TCTI themselves; see `switchTo`.
    private static var heldOnTcti = false

    /// Whether a check is running, so two don't overlap.
    private static var checking = false

    private static func startWatching() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: watchInterval, repeats: true) { _ in check() }
        RunLoop.main.add(timer, forMode: .common)
        Self.timer = timer

        // Once as soon as QEMU is up, rather than a whole interval in.
        checkOnceUp(triesLeft: 240)
    }

    /// Checks as soon as QEMU can answer, which is a moment after the boot --
    /// for up to a minute, after which a QEMU that never came up is left to the
    /// ordinary watch.
    private static func checkOnceUp(triesLeft: Int) {
        guard current != nil else {
            guard triesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                checkOnceUp(triesLeft: triesLeft - 1)
            }
            return
        }
        check()
    }

    /// Often enough to notice a loopback VPN being turned on; rarely enough
    /// that the probe costs nothing.
    private static let watchInterval: TimeInterval = 20

    /// Something changed that might make JIT possible where it wasn't: the
    /// return to the foreground, a pairing file, a prepared DDI, a new setting.
    static func conditionsMayHaveChanged() {
        waitingForChange = false
        offerDeclined = false
        failures = 0
        check()
    }

    /// Whether JIT should be looked for now, and if so, looks.
    private static func check() {
        let mode = ExecutionMode.current

        guard mode != .never, !heldOnTcti, current == .tcti, activity == .idle, !checking else {
            return
        }
        guard !waitingForChange, mayActNow else { return }

        // An offer already up is the answer to this check.
        if offer == .toNative { return }
        if mode == .dynamicAsk && offerDeclined { return }

        checking = true
        DispatchQueue.global(qos: .utility).async {
            let available = jitLooksAvailable()

            DispatchQueue.main.async {
                checking = false
                guard available, current == .tcti, activity == .idle, mayActNow else { return }

                if ExecutionMode.current.switchesToNativeAlone {
                    switchTo(.native, asked: false)
                } else if ExecutionMode.current == .dynamicAsk {
                    present(.toNative)
                }
            }
        }
    }

    /// Whether a switch to native code has a chance: what it needs is there.
    /// Not a promise, since the helper can still decline. Off the main thread.
    private static func jitLooksAvailable() -> Bool {
        if nativePrepared { return true }

        #if targetEnvironment(macCatalyst)
            return true
        #else
            switch TxmPresence.current {
            case .absent: return true
            case .unknown: return false
            case .present:
                if jit_debugger_tracing() { return true }
                return JitPairingFile.exists && TunnelProbe.probeAndReport().isAvailable
            }
        #endif
    }

    // MARK: - The code cache wanting more than JIT can give

    /// The code cache wanted to grow under native code and no helper could be
    /// reached to prepare more of it. TCTI's buffer is usable in full, so in
    /// the Dynamic modes TCTI is offered or switched to. Main thread.
    static func growthNeedsHelper() {
        // Not while the machine is away: an unpark whose cache couldn't be prepared is asked about
        // separately, and QEMU refuses to switch while its cache waits to be prepared.
        guard current == .native, activity == .idle, mayActNow else { return }

        switch ExecutionMode.current {
        case .dynamicAsk:
            present(.toTctiToGrow)
        case .dynamicAuto:
            // And not straight back: JIT returns once the helper might be reachable again.
            waitingForChange = true
            switchTo(.tcti, asked: false)
        case .always, .never:
            break
        }
    }

    // MARK: - Offers

    /// The user tapped the offer.
    static func acceptOffer() {
        guard let taken = offer else { return }
        withdrawOffer()

        switch taken {
        case .toNative: switchTo(.native, asked: true)
        case .toTctiToGrow: switchTo(.tcti, asked: true)
        }
    }

    /// The user swiped the offer away.
    static func declineOffer() {
        guard offer != nil else { return }
        Log.jit.note("backend: offer declined")
        offerDeclined = true
        withdrawOffer()
    }

    private static func present(_ value: Offer) {
        guard offer != value else { return }
        offer = value
        NotificationCenter.default.post(name: stateDidChange, object: nil)
    }

    private static func withdrawOffer() {
        guard offer != nil else { return }
        offer = nil
        NotificationCenter.default.post(name: stateDidChange, object: nil)
    }

    // MARK: - The setting

    /// Execution Mode was changed in Settings. Takes effect now. Main thread.
    static func modeChanged() {
        ExecutionMode.sessionOverride = nil
        heldOnTcti = false
        let mode = ExecutionMode.setting
        Log.jit.note("backend: execution mode now \(mode.rawValue)")

        withdrawOffer()

        if mode == .never {
            if current == .native { switchTo(.tcti, asked: false) }
            return
        }
        conditionsMayHaveChanged()
    }

    /// Flush JIT Buffers was changed in Settings. Main thread.
    static func flushSettingChanged() {
        if AppSetting.flushJitBuffers.bool { releaseNative() }
    }

    // MARK: - Publishing

    private static func publish(activity value: Activity) {
        let post = {
            guard activity != value else { return }
            activity = value
            NotificationCenter.default.post(name: stateDidChange, object: nil)
        }

        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    private static func report(_ event: Event) {
        lastEvent = event
        NotificationCenter.default.post(name: eventDidOccur, object: nil)
    }
}
