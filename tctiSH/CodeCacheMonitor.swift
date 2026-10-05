//
//  CodeCacheMonitor.swift
//  Watches the code cache fill up, and offers to make more of it usable.
//
//  Copyright © 2026 Ara Adkins.
//

import Atomics
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
        DispatchQueue.main.async {
            offersEnabled = false
            offersStoppedByFailure = true

            switch reason {
            case .noPairingFile, .attachTimedOut: helperWasMissing = true
            case .declined: break
            }
        }
    }

    /// The VM has moved to the other backend, whose buffer is another one
    /// entirely: start again from what QEMU now says. Main thread.
    static func backendChanged() {
        abandonCountdown()
        hasReportedShape = false
        lastLoggedUsed = 0
        lastReleased = qemu_code_cache_released()
        reachedMib = 0

        // A failure stopped the offers for the cache that was in use.
        if offersStoppedByFailure {
            offersEnabled = true
        }
    }

    /// Whether `offersEnabled` is off because an expansion failed rather than
    /// because the user said so. Cleared by any other change.
    private static var offersStoppedByFailure = false

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
    static var offersEnabled = true {
        didSet { offersStoppedByFailure = false }
    }

    /// Whether an expansion is under way.
    ///
    /// Main-thread only as the expansion itself runs on a background queue, so
    /// the flag it clears on the way out hops back rather than being written
    /// from there; `setPreparing` and `setReached` do the same. Read by
    /// `Backend`, which does not switch in the middle of one.
    private(set) static var isGrowing = false

    /// Set when an expansion failed for want of a helper, for `beginGrowth` to
    /// pass on once the expansion is over. Main thread.
    private static var helperWasMissing = false

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

    /// Debug Tools: shrinks a Dynamic cache to the first rung now, as memory
    /// pressure would. Returns why it didn't, or nil if it did. Should be run
    /// on the main thread.
    static func debugShrink() -> String? {
        guard CodeCache.mode == .dynamic else { return "Only a Dynamic cache shrinks." }
        guard !isGrowing else { return "An expansion is under way." }

        let target = CodeCache.growthLadder.first ?? 128
        guard qemu_code_cache_usable() > target * bytesPerMib else {
            return "It's already at \(target) MiB."
        }

        abandonCountdown()
        Log.jit.note("code cache: debug: shrinking to \(target)MiB")
        apply(shrinkTo: target)
        return nil
    }

    /// Debug Tools: grows a Dynamic cache to the next rung now, without the
    /// countdown. Returns why it didn't, or nil if it started. Should be run on
    /// the main thread.
    static func debugGrow() -> String? {
        guard !isGrowing else { return "An expansion is already under way." }
        guard !Backend.isBusy else { return "A switch of backend is under way." }
        guard canGrow, let next = nextTargetMib else {
            return "There's no room to grow, or it isn't allowed to."
        }

        abandonCountdown()
        Log.jit.note("code cache: debug: growing to \(next)MiB")
        beginGrowth(to: next * bytesPerMib)
        return nil
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

    // MARK: - While parked

    /// Hands the whole cache back while the machine is parked. Returns whether
    /// it did, in which case the machine must not run until `prepareAfterPark`
    /// has succeeded; QEMU refuses to start it meanwhile.
    ///
    /// Waits for the flush that pays it out, so call it off the main thread.
    /// Only reads and asks QEMU; nothing here touches the monitor's own state.
    static func releaseWhileParked() -> Bool {
        // Before the release, so that the poll never sees it unannounced, and so that it can't
        // start a countdown from here on.
        isParked.store(true, ordering: .relaxed)

        // One already running would expand a cache that is about to go. Harmless if it fires first,
        // since QEMU then asks for the cache to be prepared again anyway, but pointless.
        DispatchQueue.main.async { abandonCountdown() }

        guard qemu_code_cache_release_all() else {
            isParked.store(false, ordering: .relaxed)
            Log.jit.note(
                "code cache: kept while parked; under JIT, what's released here can't be "
                    + "prepared again")
            return false
        }

        if waitForReleaseAll() {
            Log.jit.note(
                "code cache: handed \(mib(qemu_code_cache_released())) back while parked")
        } else {
            // Arranged all the same, and paid out at the next flush, which `prepareAfterPark` waits
            // for.
            Log.jit.warn("code cache: no flush yet; released at the next one")
        }
        return true
    }

    /// Whether the cache has been released while parked and not yet prepared
    /// again. Quietens the poll, which would otherwise report the release a
    /// second time, and as a flush that nothing is re-translating after.
    /// Written off the main thread, read on it.
    private static let isParked = ManagedAtomic<Bool>(false)

    /// Waits for QEMU to have paid out a release of everything. Blocks; off the
    /// main thread.
    ///
    /// Asks QEMU about that release in particular. The attempt count would also
    /// move for an ordinary shrink's flush that happened to land first.
    private static func waitForReleaseAll() -> Bool {
        let deadline = Date().addingTimeInterval(parkedReleaseDeadline)

        while qemu_code_cache_release_all_outstanding() {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// How long to wait for the flush before carrying on.
    private static let parkedReleaseDeadline: TimeInterval = 5

    /// Calls off an expansion that is counting down, for a switch of backend,
    /// which leaves it describing a buffer no longer in use. Main thread.
    static func cancelPendingGrowth() {
        abandonCountdown()
    }

    /// Calls off an expansion that is counting down. Main thread.
    private static func abandonCountdown() {
        guard case .countingDown = state else { return }

        countdownWork?.cancel()
        countdownWork = nil
        countdownEndsAt = nil
        publish(.quiet)
    }

    /// Prepares the cache again after `releaseWhileParked`, as at launch. Under
    /// TXM that's a blessing with its freeze. Everywhere else it's the whole
    /// buffer.
    ///
    /// Calls `completion` on the main queue with whether it worked. Until it
    /// has, the machine must stay parked. Main thread.
    static func prepareAfterPark(completion: @escaping (Bool) -> Void) {
        // An expansion counting down from before the app went away would race this one.
        abandonCountdown()

        // As at launch, which only chunks a cache it has to bless. Everywhere else, TCTI included,
        // the whole buffer is usable from the start, and a cache that costs only what is translated
        // into it gains nothing from a limit.
        let blessing = qemu_code_cache_needs_debugger()
        let size =
            blessing
            ? (CodeCache.launchedInitialSize ?? CodeCache.initialSize) * bytesPerMib
            : qemu_code_cache_total()

        // The release has to have happened first. Still pending, the grow would be refused as
        // pointless, and the flush that finally paid it out would do so under a running machine,
        // taking pages under TXM that it was about to execute.
        DispatchQueue.global(qos: .userInitiated).async {
            guard waitForReleaseAll() else {
                Log.jit.fail("code cache: the release while parked never happened")
                DispatchQueue.main.async { completion(false) }
                return
            }

            DispatchQueue.main.async {
                prepareOnceIdle(size: size, blessing: blessing, completion: completion)
            }
        }
    }

    /// The rest of `prepareAfterPark`, once no expansion is running. Main
    /// thread.
    private static func prepareOnceIdle(
        size: Int, blessing: Bool, completion: @escaping (Bool) -> Void
    ) {
        // An expansion that began before the park finishes first, or `beginGrowth` would turn this
        // one away. Whatever it prepared, QEMU says below whether it was enough. Likewise a switch
        // of backend, which changes which buffer there is to prepare.
        guard !isGrowing, !Backend.isBusy else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                prepareOnceIdle(size: size, blessing: blessing, completion: completion)
            }
            return
        }

        isParked.store(false, ordering: .relaxed)
        lastLoggedUsed = 0
        lastReleased = qemu_code_cache_released()

        // Nothing to do if the release came to nothing, or something has prepared the cache since.
        // Asking to grow regardless would be declined as pointless, and read as a failure.
        guard qemu_code_cache_needs_preparing() else {
            Log.jit.note("code cache: nothing to prepare before the session comes back")
            completion(true)
            return
        }

        Log.jit.note(
            blessing
                ? "code cache: preparing \(mib(size)) before the session comes back"
                : "code cache: making all \(mib(size)) usable again, as at launch")
        beginGrowth(to: size, completion: completion)
    }

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

    /// In MiB, or in KiB below one, where whole MiB would read as nothing at
    /// all.
    private static func mib(_ bytes: Int) -> String {
        if bytes > 0 && bytes < bytesPerMib {
            return "\(bytes / 1024)KiB"
        }
        return "\(bytes / bytesPerMib)MiB"
    }

    private static let bytesPerMib = 1024 * 1024

    /// The most this session may ever use, in bytes.
    ///
    /// The chosen ceiling, not the mapped size. The buffer is mapped at the
    /// largest size we offer whatever was picked, because its size cannot
    /// change without a restart. The ceiling is enforced here instead, where
    /// changing it costs nothing.
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

        // `releaseWhileParked` has said what happened, and nothing runs to say more about.
        guard !isParked.load(ordering: .relaxed) else { return }

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

        guard !isGrowing, !Backend.isBusy, offersEnabled, state == .quiet, canGrow else { return }
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
    ///
    /// `completion`, if given, is called on the main queue with whether the
    /// cache grew.
    private static func beginGrowth(to next: Int, completion: ((Bool) -> Void)? = nil) {
        // Nor during a switch of backend. A countdown can run out in the middle of one, and growing
        // then decides on a debugger for one buffer and traps for the other -- or not at all,
        // leaving the helper's script waiting for a trap that never comes.
        guard !isGrowing, !Backend.isBusy else {
            completion?(false)
            return
        }

        isGrowing = true
        publish(.growing(to: next))

        DispatchQueue.global(qos: .userInitiated).async {
            let grew = grow(to: next)

            // Ahead of the state, and on the main queue with it. `poll` reads both and both have to
            // have moved before it can act again. `shrinkIfNeeded` reads this one on its own, which
            // is what keeps a pressure event from shrinking out from under an expansion that is
            // still running.
            DispatchQueue.main.async {
                isGrowing = false
                completion?(grew)

                if helperWasMissing {
                    helperWasMissing = false
                    Backend.growthNeedsHelper()
                }
            }
            publish(.quiet)
        }
    }

    /// Returns whether the cache grew.
    @discardableResult
    private static func grow(to next: Int) -> Bool {
        // Under TCTI there is nothing to prepare, so there is no debugger to find and no freeze to
        // announce. The pages are already ordinary memory and growing is raising a limit.
        guard qemu_code_cache_needs_debugger() else {
            let usable = qemu_code_cache_grow(next)
            guard usable > 0 else {
                failGrowth(.declined)
                return false
            }

            setReached(next / bytesPerMib)
            Log.jit.note("code cache: now \(mib(usable)) usable, without preparing anything")
            return true
        }

        let started = Date()

        // Something already attached owns the trap. Asking a helper to attach as well is two
        // debuggers fighting over one process, and the loser reports it as nonsense: "Failed to
        // extract registers", signal numbers in the hundreds of thousands. Mirrors what
        // `JitEnablement.enableUnderTxm()` does at launch, and needs no settle either, since a hook
        // that has been there since launch is long since armed.
        if jit_debugger_tracing() {
            Log.jit.note("code cache: a debugger is already attached; trapping into it")
            return finishGrowth(to: next, started: started)
        }

        guard let pairingData = JitPairingFile.read() else {
            failGrowth(.noPairingFile)
            return false
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
            return false
        }

        Log.jit.note(
            String(
                format: "code cache: debugger attached after %.2fs",
                -started.timeIntervalSinceNow))

        Thread.sleep(forTimeInterval: settleBeforeTrap)
        return finishGrowth(to: next, started: started)
    }

    /// Traps into whatever debugger is attached, and records what came of it.
    /// Returns whether the cache grew.
    private static func finishGrowth(to next: Int, started: Date) -> Bool {
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
            return false
        }

        // What was asked for, not what came back: see `reachedMib`.
        setReached(next / bytesPerMib)
        report(.grew(to: next))

        Log.jit.note(
            String(
                format: "code cache: now %@ usable, after %.2fs",
                mib(usable), -started.timeIntervalSinceNow))
        return true
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
