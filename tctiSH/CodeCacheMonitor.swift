//
//  CodeCacheMonitor.swift
//  Watches the code cache fill up, and offers to make more of it usable.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import os

/// Tracks how full the VM's code cache is, and expands it on request.
///
/// Only has work to do for a VM whose cache is prepared in chunks. In all other
/// cases the whole buffer is usable from the moment it is mapped.
///
/// Expanding costs a freeze as the pages are made executable by a debugger that
/// writes to each one, with all threads in the process stopped at a breakpoint.
enum CodeCacheMonitor {

    // MARK: - What the UI sees

    enum State: Equatable {
        case quiet

        /// The cache is filling up, and expanding it is about to happen unless
        /// it is stopped.
        case countingDown(next: Int)

        /// An expansion is under way. The app is about to stop responding.
        case growing(to: Int)
    }

    private(set) static var state: State = .quiet

    /// Posted on the main queue whenever `state` changes.
    static let stateDidChange = Notification.Name("io.ara.tctish.jit.codeCacheDidChange")

    /// Something that has already happened that should tell the user.
    enum Event {
        case grew(to: Int)
        case shrank(to: Int)

        /// An expansion was called off because the system asked for memory.
        case postponed

        /// An expansion was tried and did not happen.
        case failed(Failure)

        /// What the pill says.
        var message: String {
            switch self {
            case .grew(let bytes):
                return "Code cache now \(Mebibytes.describe(bytes / (1024 * 1024)))"
            case .shrank(let bytes):
                return "Code cache cut to \(Mebibytes.describe(bytes / (1024 * 1024)))"
            case .postponed:
                return "Expansion postponed, low memory"
            case .failed(let reason):
                return reason.statusMessage
            }
        }

        var symbol: String {
            switch self {
            case .grew: return "arrow.up.circle.fill"
            case .shrank: return "arrow.down.circle.fill"
            case .postponed: return "exclamationmark.circle.fill"

            // Distinct from `postponed`, which is a "not now": these did not happen and will not
            // happen again by themselves.
            case .failed: return "xmark.circle.fill"
            }
        }

        /// Whether this reports a condition rather than a size.
        ///
        /// The line the notifications setting is allowed to cut along. Growing
        /// and shrinking are size notifications, which is what the setting
        /// controls. Errors or refusals are shown regardless, as silencing the
        /// running commentary is not consent to silence the problems.
        var isWarning: Bool {
            switch self {
            case .grew, .shrank: return false
            case .postponed, .failed: return true
            }
        }
    }

    /// Why an expansion that was about to happen didn't.
    enum Failure {

        /// Nothing at `JitPairingFile.url`, so no helper to ask for a debugger.
        case noPairingFile

        /// Nothing attached within `attachDeadline`.
        case attachTimedOut

        /// QEMU had the chance and did not take it.
        case declined

        var logDescription: String {
            switch self {
            case .noPairingFile:
                return "no pairing file, so no debugger to prepare the next chunk"
            case .attachTimedOut:
                return String(format: "no debugger within %.0fs", attachDeadline)
            case .declined:
                return "QEMU declined to expand"
            }
        }

        var statusMessage: String {
            switch self {
            case .noPairingFile: return "Expansion needs a pairing file"
            case .attachTimedOut: return "Expansion failed, no debugger"
            case .declined: return "Code cache expansion failed"
            }
        }
    }

    private(set) static var lastEvent: Event?

    /// Posted on the main queue when something has happened worth reporting.
    static let eventDidOccur = Notification.Name("io.ara.tctish.jit.codeCacheEvent")

    private static func report(_ event: Event) {
        // Warnings are never silenced; see `Event.isWarning`. What the setting turns off is the
        // running commentary on the cache changing size.
        guard event.isWarning || AppSetting.codeCacheNotifications.bool else { return }

        DispatchQueue.main.async {
            lastEvent = event
            NotificationCenter.default.post(name: eventDidOccur, object: nil)
        }
    }

    /// Says an expansion didn't happen, and stops offering for the session.
    ///
    /// Both halves matter. Every one of these is a condition that will still be
    /// true at the next poll -- no pairing file, nothing attaching, a QEMU that
    /// said no -- and the cache is still over the threshold that prompted the
    /// offer, so leaving offers on means failing again every few seconds with a
    /// pill each time.
    ///
    /// Nothing is lost by stopping. Running out of usable cache makes TCG flush
    /// and re-translate, which is slower and nothing worse -- the same reason
    /// declining an expansion is safe.
    private static func failGrowth(_ reason: Failure) {
        Log.jit.warn(
            "code cache: \(reason.logDescription); not offering again unless turned back on")

        report(.failed(reason))
        DispatchQueue.main.async { offersEnabled = false }
    }

    // MARK: - Tuning

    /// How often to look.
    ///
    /// The guest translates a few MiB over a boot and then very little, so
    /// there is no need to watch closely; this is slow enough to be free and
    /// quick enough to ask before the flushing starts rather than after.
    private static let pollInterval: TimeInterval = 5

    /// How full the usable part has to get before this says anything.
    private static let offerAt = 0.75

    /// How much more has to be translated before progress is logged again.
    private static let progressStep = 32 * 1024 * 1024

    /// How long to wait for the helper's debugger to land.
    private static let attachDeadline: TimeInterval = 10

    /// How long there is to stop an expansion before it goes ahead.
    private static let countdownDuration: TimeInterval = 5

    /// How long to leave the debugger's script to arm itself before trapping.
    ///
    /// `P_TRACED` goes true when debugserver attaches, which is earlier than
    /// the script installing its handler for `brk #0xf00d`. Trapping into that
    /// gap would stop the app on a breakpoint with nobody listening, and only a
    /// force quit gets out of that. Measured at well under a second on device;
    /// this is deliberately several times that.
    private static let settleBeforeTrap: TimeInterval = 2

    // MARK: - Running

    private static var timer: Timer?

    /// Whether tctiSH may offer to grow the cache at all.
    ///
    /// Deliberately not persisted as stopping an expansion says something about
    /// the current conditions for the user, not about permanent app behavior.
    /// It is kept as a setting, however, to allow the user to toggle them back
    /// on without restarting the VM.
    static var offersEnabled = true

    /// Whether an expansion is under way.
    ///
    /// Main-thread only as the expansion itself runs on a background queue, so
    /// the flag it clears on the way out hops back rather than being written
    /// from there; `setPreparing` and `setReached` do the same.
    private static var isGrowing = false

    private static var countdownEndsAt: Date?
    private static var countdownWork: DispatchWorkItem?

    /// When the wait before the freeze began, or nil if there isn't one.
    ///
    /// Main-thread only. The tick that draws it reads it thirty times a second
    /// from there, and the growth that sets it runs on a background queue, so
    /// every write hops rather than racing.
    private static var preparationStartedAt: Date?

    /// Roughly how long finding and arming a debugger takes.
    ///
    /// Measured on device: about 1.7s for the helper to launch and attach, plus
    /// the settle. An estimate and shown as one: the ring stops just short of
    /// full rather than claiming to have finished something it cannot see.
    private static var preparationEstimate: TimeInterval { settleBeforeTrap + 1.7 }

    /// How far through that wait, 0...1, or nil when nothing is being prepared.
    static var preparationProgress: Double? {
        guard let started = preparationStartedAt else { return nil }
        return min(0.95, -started.timeIntervalSinceNow / preparationEstimate)
    }

    private static func setPreparing(_ preparing: Bool) {
        DispatchQueue.main.async { preparationStartedAt = preparing ? Date() : nil }
    }

    /// Records the rung just reached, from whichever thread reached it.
    private static func setReached(_ mib: Int) {
        DispatchQueue.main.async { reachedMib = mib }
    }

    /// How much of the countdown is left, 1 down to 0.
    ///
    /// Read by the pill, which empties its ring by it.
    static var countdownRemaining: Double {
        guard let endsAt = countdownEndsAt else { return 0 }
        return min(1, max(0, endsAt.timeIntervalSinceNow / countdownDuration))
    }

    /// Starts watching. Safe to call more than once.
    static func start() {
        guard timer == nil else { return }

        // Main-queue timer: it only reads two counters and decides whether to change a published
        // value the UI is listening to. `.common` so it keeps ticking while the terminal is being
        // scrolled.
        let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in poll() }
        RunLoop.main.add(timer, forMode: .common)
        Self.timer = timer

        MemoryPressure.start()
        NotificationCenter.default.addObserver(
            forName: MemoryPressure.didChange, object: nil, queue: .main
        ) { _ in
            pressureChanged()
        }
    }

    // MARK: - Giving it back

    /// Reacts to the system asking for memory.
    ///
    /// Growth is capped straight away for free. Then, if the cache has already
    /// climbed past what the pressure allows, the excess is handed back. This
    /// throws away every translation in it and has to be paid for again, in
    /// both re-translation and another freeze, if the guest still wants the
    /// space. Hence only doing it when the cap is actually being exceeded.
    private static func pressureChanged() {
        guard MemoryPressure.current > .normal else { return }

        // An expansion counting down when the system starts complaining is about to make things
        // worse, so it is called off rather than left to run out.
        if case .countingDown = state {
            countdownWork?.cancel()
            countdownWork = nil
            countdownEndsAt = nil
            publish(.quiet)

            // Said out loud, because the pill vanishing mid-countdown otherwise reads as the app
            // losing track of what it was doing.
            Log.jit.note("code cache: expansion called off by memory pressure")
            report(.postponed)
        }

        shrinkIfNeeded()
    }

    private static func shrinkIfNeeded() {
        guard CodeCache.mode == .dynamic, !isGrowing else { return }

        let target = shrinkTargetMib
        let usable = qemu_code_cache_usable()
        guard usable > target * bytesPerMib else { return }

        Log.jit.note(
            "code cache: \(MemoryPressure.current.description) pressure; "
                + "shrinking \(mib(usable)) to \(target)MiB")

        apply(shrinkTo: target)
    }

    /// Does the shrinking, once something has decided how far.
    private static func apply(shrinkTo target: Int) {
        let remaining = qemu_code_cache_shrink(target * bytesPerMib)
        guard remaining > 0 else {
            Log.jit.warn("code cache: QEMU declined to shrink")
            return
        }

        // What was asked for, so the ladder resumes from the right rung. The memory itself comes
        // back at the next flush, which QEMU has already asked for.
        setReached(target)
        lastLoggedUsed = 0
        report(.shrank(to: target * bytesPerMib))

        Log.jit.note("code cache: \(mib(remaining)) usable, releasing the rest at the next flush")

        // Asked for explicitly rather than waiting for the figure to change, because "nothing
        // released" and "not released yet" are the same number and only one of them is a problem.
        let attemptsBefore = qemu_code_cache_release_attempts()

        // The only answer that counts. Whether the kernel *said* yes is one thing; whether this
        // process is charged for the memory afterwards is the thing we actually wanted.
        let headroomBefore = os_proc_available_memory()

        DispatchQueue.main.asyncAfter(deadline: .now() + releaseCheckDelay) {
            let attempts = qemu_code_cache_release_attempts()
            let released = qemu_code_cache_released()
            lastReleased = released

            guard attempts > attemptsBefore else {
                Log.jit.warn(
                    "code cache: no flush within \(Int(releaseCheckDelay))s, so nothing has been "
                        + "handed back yet")
                return
            }

            guard released > 0 else {
                // The writable mapping is ordinary anonymous memory, the executable one is a shared
                // alias of it, and only one of those can be argued with.
                func outcome(_ code: Int32) -> String {
                    code == 0 ? "accepted" : String(cString: strerror(code))
                }

                Log.jit.warn(
                    "code cache: the system kept the memory -- writable mapping "
                        + "\(outcome(qemu_code_cache_release_errno())), executable mapping "
                        + "\(outcome(qemu_code_cache_release_errno_rx()))")
                return
            }

            let recovered = os_proc_available_memory() - headroomBefore

            Log.jit.note(
                "code cache: handed \(mib(released)) back; the process's headroom "
                    + "moved by \(recovered / bytesPerMib)MiB")
        }
    }

    /// How long to give the VM to reach a flush before asking what it released.
    private static let releaseCheckDelay: TimeInterval = 3

    static func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Logged once, the first time QEMU answers.
    ///
    /// Without it a session that will never offer looks exactly like one that
    /// is broken, and there is no way to tell from the outside which you have.
    private static var hasReportedShape = false

    /// The usage last written to the log, so progress is visible without
    /// flooding it.
    private static var lastLoggedUsed = 0

    /// What the last release came to, so a change in it can be reported once.
    private static var lastReleased = 0

    private static func mib(_ bytes: Int) -> String {
        "\(bytes / bytesPerMib)MiB"
    }

    private static let bytesPerMib = 1024 * 1024

    /// The most this session may ever use, in bytes.
    ///
    /// The chosen ceiling, not the mapped size. The buffer is mapped at the
    /// largest size we offer whatever was picked, because its size is the one
    /// thing that cannot change without a restart. The ceiling is enforced here
    /// instead, where changing it costs nothing.
    private static var limit: Int {
        min(CodeCache.ceiling * bytesPerMib, qemu_code_cache_total())
    }

    /// How far growth may go while the system is under pressure, in MiB.
    ///
    /// Half the chosen ceiling once the system starts complaining, and no
    /// growth at all while it is critical. Every MiB of cache is a MiB of
    /// dirty, resident memory as the debugger writes to every page to make it
    /// executable, so offering to add half a gigabyte of it during a pressure
    /// event would be putting the app first in the queue to be killed.
    private static var pressureCeilingMib: Int? {
        switch MemoryPressure.current {
        case .normal:
            return CodeCache.ceiling
        case .warning:
            return max(CodeCache.growthLadder.first ?? 128, CodeCache.ceiling / 2)
        case .critical:
            return nil
        }
    }

    /// Where a shrink aims, in MiB.
    ///
    /// Half the chosen maximum, not the rung it started on (Ara, 2026-09-16).
    /// Dropping all the way back would throw away far more than the pressure
    /// asked for, and every MiB given up has to be prepared again -- with
    /// another freeze -- if the guest turns out to still want it.
    private static var shrinkTargetMib: Int {
        max(CodeCache.growthLadder.first ?? 128, CodeCache.ceiling / 2)
    }

    /// Whether there is both room to grow and permission to.
    private static var canGrow: Bool {
        CodeCache.mode == .dynamic && qemu_code_cache_can_grow() && nextTargetMib != nil
    }

    /// How far up the ladder this session has climbed, in MiB.
    ///
    /// Tracked rather than read back from QEMU. Regions are whole-number
    /// divisions of the mapped buffer, so a 128 MiB rung comes back as a little
    /// *under* 128 MiB usable.
    ///
    /// Main-thread only; written through `setReached`.
    private static var reachedMib = 0

    /// The next rung, or nil if there isn't one we are allowed to reach.
    ///
    /// The rung to climb from is whichever is higher: what this session has
    /// already asked for, or the rung the VM is actually standing on.
    ///
    /// Both are needed. `reachedMib` is zero until the first expansion, and the
    /// obvious fallback (`CodeCache.initialSize`) describes the *next* launch
    /// rather than the running one.
    private static var nextTargetMib: Int? {
        let usableMib = qemu_code_cache_usable() / bytesPerMib
        let standingOn =
            CodeCache.growthLadder.first(where: { $0 >= usableMib })
            ?? CodeCache.growthLadder.last ?? 0

        let from = max(reachedMib, standingOn)

        guard let ceiling = pressureCeilingMib,
            from < ceiling,
            let next = CodeCache.growthLadder.first(where: { $0 > from })
        else {
            return nil
        }

        return min(next, ceiling)
    }

    private static func poll() {
        let total = qemu_code_cache_total()

        // Zero until the VM thread has opened the QEMU image and got as far as allocating. Not a
        // failure, just early.
        guard total > 0 else { return }

        let usable = qemu_code_cache_usable()
        let used = qemu_code_cache_used()
        guard usable > 0 else { return }

        if !hasReportedShape {
            hasReportedShape = true

            if canGrow {
                Log.jit.note(
                    "code cache: \(mib(usable)) usable of \(mib(total)) mapped; will offer to "
                        + "expand once \(mib(Int(Double(usable) * offerAt))) is translated")
            } else {
                Log.jit.note(
                    "code cache: \(mib(usable)) usable of \(mib(total)) mapped, limit "
                        + "\(mib(limit)) -- no expansion will be offered")
            }
        }

        // A drop means TCG ran out of room and threw everything away.
        if used < lastLoggedUsed {
            Log.jit.note(
                "code cache: flushed at \(mib(lastLoggedUsed)); re-translating from nothing")
            lastLoggedUsed = 0
        }

        let released = qemu_code_cache_released()
        if released != lastReleased {
            lastReleased = released
            Log.jit.note(
                released > 0
                    ? "code cache: handed \(mib(released)) back to the system"
                    : "code cache: could not hand anything back")
        }

        if used >= lastLoggedUsed + progressStep {
            lastLoggedUsed = used
            Log.jit.note("code cache: \(mib(used)) of \(mib(usable)) translated")
        }

        guard !isGrowing, offersEnabled, state == .quiet, canGrow else { return }
        guard Double(used) / Double(usable) >= offerAt else { return }
        guard let nextMib = nextTargetMib else { return }

        let next = nextMib * bytesPerMib

        // With notifications off, expanding stops being a question.
        guard AppSetting.codeCacheNotifications.bool else {
            Log.jit.note(
                "code cache: \(mib(used)) of \(mib(usable)) used; expanding to \(mib(next))")
            beginGrowth(to: next)
            return
        }

        Log.jit.note(
            "code cache: \(mib(used)) of \(mib(usable)) used; expanding to \(mib(next)) in "
                + "\(Int(countdownDuration))s unless stopped")
        startCountdown(to: next)
    }

    /// Says what is about to happen, and leaves a moment to prevent it.
    private static func startCountdown(to next: Int) {
        countdownWork?.cancel()

        let work = DispatchWorkItem {
            countdownEndsAt = nil
            countdownWork = nil

            guard case .countingDown(let target) = state else { return }
            beginGrowth(to: target)
        }

        countdownWork = work
        countdownEndsAt = Date().addingTimeInterval(countdownDuration)
        publish(.countingDown(next: next))

        DispatchQueue.main.asyncAfter(deadline: .now() + countdownDuration, execute: work)
    }

    /// Stops an expansion that was about to happen, for the rest of the session
    /// or until the user re-enables it in settings.
    static func cancelGrowth() {
        countdownWork?.cancel()
        countdownWork = nil
        countdownEndsAt = nil

        guard case .countingDown = state else { return }

        Log.jit.note("code cache: expansion stopped; not offering again unless turned back on")
        offersEnabled = false
        publish(.quiet)
    }

    // MARK: - Expanding

    /// Accepts the offer, and does the work.
    ///
    /// Returns immediately; the expansion runs off the main thread because the
    /// banner it puts up has to be committed to a frame from somewhere that can
    /// block waiting for one.
    private static func beginGrowth(to next: Int) {
        guard !isGrowing else { return }

        isGrowing = true
        publish(.growing(to: next))

        DispatchQueue.global(qos: .userInitiated).async {
            grow(to: next)

            // Ahead of the state, and on the main queue with it. `poll` reads both and both have to
            // have moved before it can act again. `shrinkIfNeeded` reads this one on its own, which
            // is what keeps a pressure event from shrinking out from under an expansion that is
            // still running.
            DispatchQueue.main.async { isGrowing = false }
            publish(.quiet)
        }
    }

    private static func grow(to next: Int) {
        // Under TCTI there is nothing to prepare, so there is no debugger to find and no freeze to
        // announce. The pages are already ordinary memory and growing is raising a limit.
        guard qemu_code_cache_needs_debugger() else {
            let usable = qemu_code_cache_grow(next)
            guard usable > 0 else {
                failGrowth(.declined)
                return
            }

            setReached(next / bytesPerMib)
            Log.jit.note("code cache: now \(mib(usable)) usable, without preparing anything")
            report(.grew(to: next))
            return
        }

        let started = Date()

        // Something already attached owns the trap. Asking a helper to attach as well is two
        // debuggers fighting over one process, and the loser reports it as nonsense: "Failed to
        // extract registers", signal numbers in the hundreds of thousands. Mirrors what
        // `JitEnablement.enableUnderTxm()` does at launch, and needs no settle either, since a hook
        // that has been there since launch is long since armed.
        if jit_debugger_tracing() {
            Log.jit.note("code cache: a debugger is already attached; trapping into it")
            finishGrowth(to: next, started: started)
            return
        }

        guard let pairingData = JitPairingFile.read() else {
            failGrowth(.noPairingFile)
            return
        }

        // From here until the trap, the app keeps running and there is a visible wait to explain.
        setPreparing(true)
        defer { setPreparing(false) }

        // Returns only once the script has been let go, which is what the trap below does. Nothing
        // waits on it: the attach is what matters, and that lands long before this returns.
        JITHelperClient.enable(pairingData: pairingData, targetPID: getpid()) { reply in
            Log.jit.note("code cache: helper returned \(reply?.detail ?? "nothing")")
        }

        guard waitForDebugger() else {
            failGrowth(.attachTimedOut)
            return
        }

        Log.jit.note(
            String(
                format: "code cache: debugger attached after %.2fs",
                -started.timeIntervalSinceNow))

        Thread.sleep(forTimeInterval: settleBeforeTrap)
        finishGrowth(to: next, started: started)
    }

    /// Traps into whatever debugger is attached, and records what came of it.
    private static func finishGrowth(to next: Int, started: Date) {
        // The waiting is over; what follows is the freeze, which the banner covers instead.
        setPreparing(false)

        // Up, and committed to a frame, immediately before the freeze and not a moment sooner.
        FreezeBanner.raiseAndWait(
            "Expanding code cache to \(Mebibytes.describe(next / bytesPerMib))…")
        defer { FreezeBanner.lower() }

        // The freeze. Every thread stops here until the last page has been written to.
        let usable = qemu_code_cache_grow(next)

        guard usable > 0 else {
            failGrowth(.declined)
            return
        }

        // What was asked for, not what came back: see `reachedMib`.
        setReached(next / bytesPerMib)
        report(.grew(to: next))

        Log.jit.note(
            String(
                format: "code cache: now %@ usable, after %.2fs",
                mib(usable), -started.timeIntervalSinceNow))
    }

    /// Blocks until a debugger attaches, or time runs out.
    private static func waitForDebugger() -> Bool {
        let deadline = Date().addingTimeInterval(attachDeadline)

        while Date() < deadline {
            if jit_debugger_tracing() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.025)
        }

        return false
    }

    private static func publish(_ value: State) {
        DispatchQueue.main.async {
            guard state != value else { return }

            state = value
            NotificationCenter.default.post(name: stateDidChange, object: nil)
        }
    }
}
