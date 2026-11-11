//
//  QEMULauncher
//  Swift interfacing code for launching our internal QEMU.
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright ©2022 Kate Temkin. All rights reserved.
//

import Atomics
import Foundation

/// Structure that stores the metadata associated with a given mount.
struct DiskMountInfo: Codable {

    /// The bookmark data assosciated with the disk mount.
    var bookmark: Data

    /// The tag used for configuring the fsdev backing file provider.
    var fsdev_tag: String

    /// The tag used for mounting the device into the VM.
    var mount_tag: String

    /// Where the guest mounts it, so that the next boot mounts it there again.
    /// Nil in slots saved before mountpoints were kept.
    var mountpoints: [String]?
}

/// Provides an interface for running / controlling a QEMU VM.
public class QEMUInterface {

    /// The port on which we connect using the QEMU monitor.
    private static let monitorPort: Int32 = 10044

    /// Our QEMU human-readable protocol socket.
    ///
    /// Private, and touched only with `monitorLock` held: there is one of these
    /// and more than one thread that wants it.
    private var monitorSocket: SocketConnection?
    private var monitorSocketPath: String?

    /// The disk this launch runs from, fixed when the interface is made.
    ///
    /// Not the setting, which can be changed while the VM runs: Settings says a
    /// new name takes effect the next time tctiSH opens, and until then
    /// everything written about a disk (the saved session, the persistent
    /// mounts) belongs to the one the VM actually has open. Reading the setting
    /// each time instead pointed another disk at a snapshot that is only on
    /// this one. A `let`, so any thread can read it.
    let disk: String

    init() {
        disk = Self.diskNameSetting()
    }

    /// Start our background QEMU thread.
    func startQemuThread(forceRecoveryBoot: Bool = false) {

        // Clear any state left over from previous runs.
        clearLastCWDFile()
        Self.removeSocketsFromDocuments()

        // Figure out where our QEMU resources are...
        let bundlePrefix = Bundle.main.resourcePath!
        let kernelPath = bundlePrefix + "/" + "bzImage"
        let initrdPath = bundlePrefix + "/" + "initrd.img"

        // ... get a disk to run with ...
        let diskPath = getPersistentStore().path
        Log.fs.note("disk path: \(diskPath)")

        // ... figure out which image we'll be restoring state from ...
        let bootImageName = getBootImageName(forceRecoveryBoot: forceRecoveryBoot)

        // Noted so that a pointer QEMU cannot follow can be disowned; see
        // `forgetMissingResumeImage`. Only when it came from `resume_image`: a tag typed into Boot
        // From Snapshot is the user's, and quietly erasing what someone typed is not a repair.
        let fromResumeImage = bootImageName != nil && bootImageName == getResumeImage()
        DispatchQueue.main.async { self.bootedFromResumeImage = fromResumeImage }

        // A snapshot booted in an earlier launch, so Kernel Log has nothing from before it.
        if let bootImageName {
            let from =
                fromResumeImage
                ? "Resuming a saved session."
                : bootImageName == "instantboot"
                    ? "Starting from the clean boot snapshot."
                    : "Starting from the snapshot \(bootImageName)."
            DispatchQueue.main.async {
                ChardevTransport.kernelLog.note(
                    "\(from) What the kernel said before then is in dmesg.")
            }
        }

        // QEMU appends to the serial port's log, so the last launch's has to go first.
        let serialLogPath = ChardevTransport.kernelLog.logPath!
        if unlink(serialLogPath) != 0, errno != ENOENT {
            Log.qemu.warn("couldn't remove the old serial log: \(String(cString: strerror(errno)))")
        }

        // ... find where our QEMU binary is actually located ...
        let qemuImage = getAppropriateQemuFramework().path

        // ... figure out the folder we'll be sharing into our environment ...
        let sharedFolder = getSharedFolder().path

        // ... figure out how much memory to give the VM, and how much code cache ...
        let memoryValue = VmMemory.qemuArgument
        let tbSize = CodeCache.tbSizeArgument

        // ... and how many vCPUs: what a resumed session had, so that loading it has nothing to
        // change, and otherwise the setting. Either way they are brought to what is wanted once
        // Linux is up.
        let vcpus = launchVcpus(bootImageName: bootImageName)

        // ... get a filename for our unix domain monitor-connection socket ...
        monitorSocketPath = Self.socketPath("monitor")

        // ... and for the consoles, which the launcher copies, so the copies made here are freed
        // once it returns ...
        let consoleSocketPaths = (0..<Int(TCTISH_CONSOLE_COUNT)).map {
            UnsafePointer(strdup(Self.consoleSocketPath("hvc\($0)")))
        }
        defer { consoleSocketPaths.forEach { free(UnsafeMutablePointer(mutating: $0)) } }

        // Read once, so the log matches the launch.
        let rcg = AppSetting.rcg.bool

        // Say what we're about to run. A hung VM looks identical whichever build and boot image
        // produced it, and those are exactly the two things that determine whether it *can* boot --
        // a snapshot taken under one QEMU build is not necessarily loadable by the other.
        Log.qemu.note(
            "\(getAppropriateQemuFramework().lastPathComponent), "
                + "accel tcg,tcti=\(AppDelegate.startsNative ? "off" : "on"),split-wx=on,"
                + "tb-size=\(tbSize)\(rcg ? ",rcg=on" : ""), "
                + "bless \(AppDelegate.blessJitRegions)")
        Log.qemu.note(
            "\(bootImageName.map { "resuming from '\($0)'" } ?? "cold boot"), "
                + "memory \(memoryValue), code cache \(CodeCache.summary), "
                + "\(vcpus) of \(Vcpus.maximum) vCPUs")

        // ... and start up the QEMU kernel, which will start paused.
        run_background_qemu(
            qemuImage, kernelPath, initrdPath, bundlePrefix, diskPath, sharedFolder, bootImageName,
            memoryValue, monitorSocketPath, consoleSocketPaths, Self.agentSocketPath,
            Self.controlSocketPath, ChardevTransport.kernelLog.socketPath, serialLogPath,
            ChardevTransport.vmManagement.socketPath, AppDelegate.startsNative,
            rcg, AppDelegate.blessJitRegions,
            UInt32(tbSize), UInt32(CodeCache.initialSize), UInt32(vcpus));
        Vcpus.launched(with: vcpus)
        DispatchQueue.main.async { ChardevTransport.kernelLog.followLog() }

        // Mark what we booted with, so the next launch can tell whether the settings moved.
        VmMemory.recordBooted()
        CodeCache.recordBooted()

        // Finally, recreate our persistent mounts, so they're available in the VM.
        recreatePersistentMounts()
    }

    /// Whether this launch was told to resume from `resume_image`.
    ///
    /// Main-thread only. `startQemuThread` runs on `AppDelegate.bootQueue` and
    /// the watcher that reads this is a main-queue timer, so the write hops
    /// rather than racing as `CodeCacheMonitor` does with the flags it sets
    /// from its growth queue. Nothing reads it until QEMU has opened the disk
    /// and had its say, which is seconds after the hop lands.
    private var bootedFromResumeImage = false

    /// Stops pointing at a snapshot QEMU has said is not there.
    ///
    /// Left alone, a `resume_image` naming a snapshot that does not exist is
    /// permanent: it is only ever rewritten by a save that succeeds, so until
    /// one does, every launch pays the same failed lookup and says the same
    /// thing about it. Clearing it means the next launch is an honest cold boot
    /// instead of a resume that cannot happen, and the save that eventually
    /// works fills it back in.
    ///
    /// Only the pointer this app maintains. A tag someone typed into Boot From
    /// Snapshot is theirs, and the right response to that one being missing is
    /// to say so, which already happens.
    ///
    /// Returns whether anything was forgotten. Main thread only; see
    /// `bootedFromResumeImage`.
    @discardableResult
    func forgetMissingResumeImage() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        guard bootedFromResumeImage else { return false }
        bootedFromResumeImage = false

        let stale = getResumeImage()
        guard !stale.isEmpty else { return false }

        Log.qemu.warn("resume: '\(stale)' is not on the disk; forgetting it")
        setResumeImage(tag: "")
        return true
    }

    /// Whether the last attempt to save the session failed.
    ///
    /// Persisted, because of when the failure happens. The save runs as the app
    /// is going into the background, so there is often nobody looking at the
    /// screen to be told. By the time anyone is, this process may be gone. The
    /// UI clears it once it has said so.
    ///
    /// Also set once a save runs past its deadline, in case it never finishes;
    /// a save that works clears it.
    static var lastSaveFailed: Bool {
        get { UserDefaults.standard.bool(forKey: "last_save_failed") }
        set { UserDefaults.standard.set(newValue, forKey: "last_save_failed") }
    }

    /// When a save last succeeded, on any disk: for Debug Tools, and to tell at
    /// a background task's expiry whether its save has worked already.
    static var lastSavedAt: Date? {
        get { UserDefaults.standard.object(forKey: "last_saved_at") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "last_saved_at") }
    }

    /// When a save last failed, for Debug Tools.
    ///
    /// Not `lastSaveFailed`, which the UI clears once it has said so, and so
    /// can't say what the last attempt came to afterwards.
    static var lastSaveFailedAt: Date? {
        get { UserDefaults.standard.object(forKey: "last_save_failed_at") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "last_save_failed_at") }
    }

    /// How a background save ended.
    enum BackgroundSave {
        case failed

        /// Saved, and the machine carried on running.
        case saved

        /// Saved as `tag`, and the machine left stopped at exactly the state
        /// the snapshot holds, ready to `park`. The caller must either park it
        /// or `continueStopped()` it.
        case savedAndStopped(tag: String)
    }

    /// Snapshots the session, and points the next launch at it if it worked.
    ///
    /// With `leavingStopped`, stops the machine first and leaves it stopped
    /// after a successful save, so that the snapshot and the machine agree and
    /// the machine can be parked. A save that fails, or a machine that won't
    /// stop, goes on as an ordinary save: the machine is left running.
    ///
    /// Call off the main thread, and only once Linux is up: a snapshot of a
    /// machine that has not finished booting is not worth resuming, and the
    /// check is the guest agent's, so the caller makes it.
    @discardableResult
    func performBackgroundSave(leavingStopped: Bool = false) -> BackgroundSave {
        // See snapshotWorkLock: this whole sequence has to be atomic against a stale-snapshot
        // discard, which deletes the very tags this rotates between.
        Self.snapshotWorkLock.lock()
        defer { Self.snapshotWorkLock.unlock() }

        // `savevm` stops the machine for its duration and starts it again, so a machine that is to
        // stay stopped has to be stopped beforehand.
        let stopped = leavingStopped && runMonitorCommandCleanly("stop", purpose: "park: stop")

        // A `stop` that answered late still stopped the machine, and the save that follows would
        // leave it that way. Harmless on a machine that is running.
        if leavingStopped && !stopped {
            continueStopped()
        }

        let tag = getNextInstantResumeTag()

        guard saveSession(as: tag, waitingPastDeadline: true) else {
            if stopped {
                continueStopped()
            }
            return .failed
        }

        return stopped ? .savedAndStopped(tag: tag) : .saved
    }

    /// Gives a stopped, saved machine's RAM back to the host.
    ///
    /// Our QEMU's `park` hands all of the stopped machine's RAM back to iOS,
    /// and `unpark` loads it back from the snapshot just taken, so a parked
    /// machine costs nothing for its memory while the app is away.
    ///
    /// Returns whether it is parked. If it isn't, it has been started again.
    func park() -> Bool {
        Self.snapshotWorkLock.lock()
        defer { Self.snapshotWorkLock.unlock() }

        if runMonitorCommandCleanly("park", purpose: "park", timeout: Self.unparkDeadline) {
            return true
        }

        // Not parked as far as we know, so it has to run again. Unless it was all the same: a
        // `park` that answered too late still did its work, and then QEMU refuses the `cont`.
        guard let reply = runMonitorCommand("cont", timeout: Self.monitorReplyDeadline) else {
            Log.qemu.warn("park: 'cont' got no answer")
            return false
        }

        if let failure = Self.monitorError(in: reply) {
            if failure.contains("parked") {
                Log.qemu.note("park: 'park' finished after all")
                return true
            }
            Log.qemu.warn("park: 'cont' refused: \(failure)")
        }

        return false
    }

    /// Brings a parked machine back from `tag`, the snapshot it was parked on,
    /// and starts it with its clock caught up.
    ///
    /// Returns whether it is running. If it isn't, it is still parked: QEMU
    /// refuses to `cont` a machine whose RAM hasn't been loaded back, and the
    /// only ways on are another `unpark` or a hard reset.
    func unpark(tag: String) -> Bool {
        Self.snapshotWorkLock.lock()
        defer { Self.snapshotWorkLock.unlock() }

        let started = Date()
        let failure: String?
        if let reply = runMonitorCommand("unpark \(tag)", timeout: Self.unparkDeadline) {
            failure = Self.monitorError(in: reply)
        } else {
            failure = "no answer within \(Int(Self.unparkDeadline))s"
        }

        guard let failure else {
            // Logged every time. How long a return takes is what the setting's description quotes.
            Log.qemu.note(
                String(format: "park: unparked '%@' in %.2fs", tag, -started.timeIntervalSinceNow))
            return true
        }

        // An `unpark` that answered too late still loaded and started the machine, and trying again
        // is then refused as not parked. Running is what was asked for, however it got there.
        if machineIsRunning() {
            Log.qemu.note("park: 'unpark \(tag)' said '\(failure)', but the machine is running")
            return true
        }

        Log.qemu.warn("park: 'unpark \(tag)' failed: \(failure)")
        return false
    }

    /// Whether QEMU says the machine is running, asked a few times over.
    ///
    /// More than once because it follows a command that may have answered too
    /// late, and whose reply can still be in the way of this one's.
    private func machineIsRunning() -> Bool {
        for _ in 0..<3 {
            guard let reply = runMonitorCommand("info status", timeout: Self.monitorReplyDeadline)
            else { continue }

            if let status = Self.lines(of: reply).first(where: { $0.contains("VM status:") }) {
                return status.contains("VM status: running")
            }
        }

        return false
    }

    /// Starts a machine that a save left stopped and that isn't going to be
    /// parked after all.
    func continueStopped() {
        runMonitorCommandCleanly("cont", purpose: "park: cont")
    }

    // MARK: vCPUs

    /// The vCPU slots QEMU has, plugged in or not.
    struct VcpuSlots {

        /// One slot: the QOM type to plug into it, its place in the topology,
        /// and where the vCPU in it lives, if one exists.
        struct Slot {
            let type: String
            let properties: [(name: String, value: String)]
            let qomPath: String?

            var core: Int {
                properties.first { $0.name == "core-id" }.flatMap { Int($0.value) } ?? 0
            }
        }

        /// Every slot, in core order.
        let slots: [Slot]

        var plugged: [Slot] { slots.filter { $0.qomPath != nil } }
        var empty: [Slot] { slots.filter { $0.qomPath == nil } }

        /// Reads the monitor's listing.
        ///
        /// Each slot starts at its `type:` line. The values are always quoted,
        /// and the properties are the indented `name: "value"` lines after
        /// `CPUInstance Properties:`, which name the slot exactly as
        /// `device_add` wants it named.
        init(parsing reply: String) {
            var slots: [Slot] = []
            var type: String?
            var properties: [(name: String, value: String)] = []
            var qomPath: String?

            func finish() {
                if let type {
                    slots.append(Slot(type: type, properties: properties, qomPath: qomPath))
                }
                type = nil
                properties = []
                qomPath = nil
            }

            for line in QEMUInterface.lines(of: reply) {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard let colon = text.firstIndex(of: ":") else { continue }

                let name = String(text[..<colon])
                let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard rest.count >= 2, rest.first == "\"", rest.last == "\"" else { continue }
                let value = String(rest.dropFirst().dropLast())

                switch name {
                case "type":
                    finish()
                    type = value
                case "qom_path": qomPath = value
                case "vcpus_count": break
                default: properties.append((name, value))
                }
            }
            finish()

            self.slots = slots.sorted { $0.core < $1.core }
        }
    }

    /// The vCPU slots, or nil if QEMU wouldn't list them.
    private func vcpuSlots() -> VcpuSlots? {
        guard
            let reply = runMonitorCommand(
                "info hotpluggable-cpus", timeout: Self.monitorReplyDeadline)
        else {
            return nil
        }

        if let failure = Self.monitorError(in: reply) {
            Log.qemu.warn("vcpus: 'info hotpluggable-cpus' refused: \(failure)")
            return nil
        }

        let slots = VcpuSlots(parsing: reply)
        return slots.slots.isEmpty ? nil : slots
    }

    /// How long Linux may take to let a vCPU go.
    ///
    /// An unplug is a request: QEMU tells the guest, the guest moves its work
    /// off the CPU and takes it offline, and only then ejects it.
    private static let vcpuUnplugDeadline: TimeInterval = 5

    /// The core of an unplug Linux hadn't finished when `unplugVcpu` stopped
    /// waiting, while it is still plugged in.
    ///
    /// Asked for is asked for: the guest can still let it go at any moment.
    /// Plugging another vCPU meanwhile would fill the slot above it, and then
    /// its going would leave a gap, cores 0 to n-1 no longer being what is
    /// there. So nothing is plugged while one is outstanding. Touched only from
    /// `changeVcpus`, which runs on `Vcpus`'s one serial queue.
    private var unplugOutstanding: Int?

    /// Forgets an unplug that was still outstanding, because Linux was reset.
    ///
    /// A reset withdraws the eject request along with everything else, so the
    /// vCPU it was for stays, and plugging must not wait for it to go. Only
    /// from `Vcpus`'s queue, like `changeVcpus`.
    func forgetOutstandingUnplug() {
        if let core = unplugOutstanding {
            Log.qemu.note("vcpus: no longer waiting for core \(core) to go, as Linux was reset")
        }
        unplugOutstanding = nil
    }

    /// Plugs vCPUs in or unplugs them, one at a time, toward `target`, and
    /// returns how many there are afterwards, or nil if QEMU wouldn't say.
    ///
    /// Always at the top: plugging fills the lowest empty core, and unplugging
    /// empties the highest, which is never core 0. The vCPUs are then cores 0
    /// to n-1, which is what `-smp cpus=n` builds, so the launch that resumes a
    /// session usually has nothing to change. When it does, QEMU brings the
    /// machine to the snapshot's vCPUs as it loads.
    ///
    /// Each `device_add` and `device_del` is made under `snapshotWorkLock`, so
    /// never in the middle of a save or a park, but the lock is not held while
    /// Linux lets a vCPU go, or between steps: a save waits for one command at
    /// most. Blocks while Linux lets each vCPU go, so only from `Vcpus`'s
    /// queue.
    func changeVcpus(toward target: () -> Int?) -> Int? {
        guard var slots = vcpuSlots() else { return nil }
        let before = slots.plugged.count

        if let core = unplugOutstanding, !slots.plugged.contains(where: { $0.core == core }) {
            Log.qemu.note("vcpus: Linux has let core \(core) go after all")
            unplugOutstanding = nil
        }

        while let wanted = target() {
            let wanted = min(max(wanted, 1), slots.slots.count)
            let present = slots.plugged.count
            guard present != wanted else { break }

            if present < wanted, let core = unplugOutstanding {
                Log.qemu.note("vcpus: not plugging in while core \(core) is still being unplugged")
                break
            }

            let changed = present < wanted ? plugVcpu(into: slots) : unplugVcpu(from: slots)
            guard changed, let after = vcpuSlots() else { break }
            slots = after
        }

        let now = slots.plugged.count
        if now != before {
            Log.qemu.note("vcpus: \(before) -> \(now)")
        }
        return now
    }

    /// Plugs a vCPU into the lowest empty core, and says whether it went in.
    ///
    /// Done as far as QEMU is concerned once `device_add` returns. Linux hears
    /// of it over ACPI and brings it online, through `tctish-cpu-online`.
    private func plugVcpu(into slots: VcpuSlots) -> Bool {
        guard let slot = slots.empty.first else { return false }

        let placement = slot.properties.map { "\($0.name)=\($0.value)" }.joined(separator: ",")

        Self.snapshotWorkLock.lock()
        defer { Self.snapshotWorkLock.unlock() }
        return runMonitorCommandCleanly(
            "device_add \(slot.type),id=vcpu\(slot.core),\(placement)", purpose: "vcpus")
    }

    /// Unplugs the vCPU in the highest core, and says whether it has gone.
    ///
    /// Waits for Linux to let it go, up to `vcpuUnplugDeadline`, without the
    /// snapshot lock: a save meanwhile stops the guest, so the vCPU can't go in
    /// the middle of one, and QEMU records which vCPUs a snapshot has. One that
    /// hasn't gone by then is remembered in `unplugOutstanding`.
    private func unplugVcpu(from slots: VcpuSlots) -> Bool {
        guard let slot = slots.plugged.last, slot.core != 0, let path = slot.qomPath else {
            return false
        }

        let asked: Bool = {
            Self.snapshotWorkLock.lock()
            defer { Self.snapshotWorkLock.unlock() }
            return runMonitorCommandCleanly("device_del \(path)", purpose: "vcpus")
        }()
        guard asked else { return false }

        let gone = { [self] in
            vcpuSlots().map { !$0.plugged.contains(where: { $0.core == slot.core }) } ?? false
        }

        let deadline = Date().addingTimeInterval(Self.vcpuUnplugDeadline)
        while Date() < deadline {
            if gone() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Once more past the deadline: a process suspended in the middle of the wait wakes up with
        // it already gone, and Linux may have finished long ago.
        if gone() { return true }

        Log.qemu.warn(
            "vcpus: Linux hasn't let core \(slot.core) go within "
                + "\(Int(Self.vcpuUnplugDeadline))s; leaving it asked for")
        unplugOutstanding = slot.core
        return false
    }

    /// Runs a monitor command, and says whether it came back without an error.
    ///
    /// The refusal goes to the log verbatim, under `purpose`.
    @discardableResult
    private func runMonitorCommandCleanly(
        _ command: String, purpose: String,
        timeout: TimeInterval = QEMUInterface.monitorReplyDeadline
    ) -> Bool {
        guard let reply = runMonitorCommand(command, timeout: timeout) else {
            Log.qemu.warn("\(purpose): '\(command)' got no answer")
            return false
        }

        if let failure = Self.monitorError(in: reply) {
            Log.qemu.warn("\(purpose): '\(command)' refused: \(failure)")
            return false
        }

        return true
    }

    /// How long a return from parking may take before we stop waiting.
    ///
    /// Longer than a save's, because it runs in the foreground with nothing
    /// else to hurry it along, and cut short it leaves the machine parked.
    private static let unparkDeadline: TimeInterval = 60

    /// Writes the snapshot, checks it, and points the next launch at it. Call
    /// with `snapshotWorkLock` held.
    ///
    /// With `waitingPastDeadline`, a save past its deadline is reported as
    /// failed, but still waited for: QEMU carries on with it, and a snapshot
    /// that finishes is as good as any other, so it's checked and used as
    /// usual. Only the background save waits past the deadline: every save
    /// holds `snapshotWorkLock`, and a background save queued behind, say, a
    /// compaction's save would wait as long as that one did.
    private func saveSession(as tag: String, waitingPastDeadline: Bool = false) -> Bool {
        let started = Date()

        guard
            let reply = runMonitorCommand(
                "savevm \(tag)", timeout: Self.saveDeadline,
                lateWait: waitingPastDeadline ? Self.lateSaveWait : nil,
                whenLate: { self.reportSaveRunningLate(tag) })
        else {
            let waited = Self.saveDeadline + (waitingPastDeadline ? Self.lateSaveWait : 0)
            reportSaveFailure(
                "'savevm \(tag)' did not finish within \(Int(waited))s of the app running")
            return false
        }

        let elapsed = -started.timeIntervalSinceNow

        // Logged every time, not just on the way out. How long a snapshot takes is the number this
        // whole path is sized against.
        Log.qemu.note(
            String(format: "session save: 'savevm %@' returned after %.1fs", tag, elapsed))

        // A failed HMP command says why, on the monitor, and the reason is worth having verbatim.
        if let failure = Self.monitorError(in: reply) {
            reportSaveFailure("savevm refused: \(failure)")
            return false
        }

        guard snapshotIsLoadable(tag: tag) else {
            reportSaveFailure("'\(tag)' is not loadable; leaving the previous snapshot in place")
            return false
        }

        // How many vCPUs to launch with to resume it. A head start rather than a requirement: QEMU
        // records which vCPUs the snapshot has, and brings the machine to them as it loads.
        let vcpus = vcpuSlots()?.plugged.count

        // Only having been told the snapshot is really there. Stamped with the machine that is
        // running, which is what the snapshot holds; see `resumeStamp`.
        let stamp = VmMemory.bootedArgument.map { VmSnapshots.resumeStamp(memory: $0) } ?? ""
        setResumeImage(tag: tag, stamp: stamp, vcpus: vcpus)
        Self.lastSaveFailed = false
        Self.lastSavedAt = Date()

        // Including any alert `reportSaveRanOutOfTime` queued. The assertion running out did not
        // stop the work, and the work went on to succeed, perhaps past its deadline.
        LocalAlert.withdraw(id: Self.saveFailureAlertId)

        Log.qemu.note("session save: resuming from '\(tag)' next time")
        return true
    }

    /// Posted on the main queue when a save has failed.
    static let saveDidFail = Notification.Name("io.ara.tctish.saveDidFail")

    /// Records that the session was not saved, and says so where it will be
    /// seen.
    func reportSaveFailure(_ reason: String) {
        Log.qemu.warn("session save: \(reason)")
        Self.lastSaveFailed = true
        Self.lastSaveFailedAt = Date()

        LocalAlert.post(
            title: Self.saveFailureTitle,
            body: Self.saveFailureBody,
            id: Self.saveFailureAlertId)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.saveDidFail, object: nil)
        }
    }

    /// Records that `savevm` has missed its deadline, while it is still waited
    /// for. The flag is set now, in case the process is killed before the save
    /// finishes: it's what the next launch has to go on. A save that works
    /// clears it.
    ///
    /// No alert: in the background, the background task's expiry queues one
    /// (`reportSaveRanOutOfTime`), and in front, someone is watching the
    /// terminal wait for the save. Nor `saveDidFail`, which would tell them a
    /// save still running has failed.
    private func reportSaveRunningLate(_ tag: String) {
        Log.qemu.warn(
            "session save: 'savevm \(tag)' did not finish within \(Int(Self.saveDeadline))s; "
                + "waiting for it")
        Self.lastSaveFailed = true
    }

    /// Records that the save has run out of time, and says so unless it
    /// finishes after all.
    ///
    /// Not `reportSaveFailure`, because an assertion expiring is a different
    /// fact from a save that failed. iOS is saying "hand this back now"; it is
    /// not stopping the work, which carries on under its deadlines and quite
    /// often succeeds.
    ///
    /// The alert waits `saveAlertGrace` first, a last chance for the save to
    /// finish. It can still finish after that, and withdraws the alert if it
    /// does.
    ///
    /// Does nothing if a save has worked since `since`, when this round of
    /// saving began, since no later save would withdraw the alert; nor if one
    /// has failed since, which has said so already. Checks again after posting,
    /// in case a save finished in between.
    func reportSaveRanOutOfTime(unlessSavedSince since: Date) {
        let savedSince = { Self.lastSavedAt.map { $0 >= since } ?? false }
        let failedSince = Self.lastSaveFailedAt.map { $0 >= since } ?? false
        guard !savedSince(), !failedSince else { return }

        Log.qemu.warn("session save: ran out of time in the background")
        Self.lastSaveFailed = true

        LocalAlert.post(
            title: Self.saveFailureTitle,
            body: Self.saveFailureBody,
            id: Self.saveFailureAlertId,
            after: Self.saveAlertGrace)

        if savedSince() {
            Self.lastSaveFailed = false
            LocalAlert.withdraw(id: Self.saveFailureAlertId)
        }
    }

    /// Takes down the "Session not saved" alert, queued or shown, and leaves
    /// `lastSaveFailed` set. For when someone has come back to wait on the
    /// save: if it fails, the app says so with a pill.
    func withdrawSaveFailureAlert() {
        LocalAlert.withdraw(id: Self.saveFailureAlertId)
    }

    /// What resuming will do, rather than by what is "lost", because which of
    /// those is true depends on what happens next.
    private static let saveFailureTitle = "Session not saved"

    private static let saveFailureBody =
        "tctiSH couldn't snapshot your Linux session. Resuming will take you back to "
        + "the last successful save."

    private static let saveFailureAlertId = "session-save-failed"

    /// The reason an HMP command gave for refusing, if it refused.
    ///
    /// `hmp_handle_error` prefixes every one with "Error: ", so the marker is
    /// reliable; what follows it is one line of prose written for a person.
    private static func monitorError(in reply: String) -> String? {
        for line in Self.lines(of: reply) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if text.hasPrefix("Error: ") {
                return String(text.dropFirst("Error: ".count))
            }
        }

        return nil
    }

    /// How long a snapshot may take before it counts as failed. It is still
    /// waited for, `lateSaveWait` longer.
    ///
    /// Sized against what iOS gives a background task rather than against any
    /// measurement of `savevm`, which scales with how much RAM the guest was
    /// given and can be several gigabytes of it. iOS gives a background task
    /// about 30 s. The guest's preparation usually takes a few seconds of the
    /// 12 it may have (`GuestPreparation.deadline`), and a trimmed guest saves
    /// in under 8.
    private static let saveDeadline: TimeInterval = 20

    /// How long the "Session not saved" alert from a background task's expiry
    /// waits before it goes out: only a grace period, for a save just about to
    /// finish, which then withdraws it.
    private static let saveAlertGrace: TimeInterval = 20

    /// How much longer a snapshot past `saveDeadline` is waited for. Long,
    /// because nothing is lost by it: `savevm` holds the machine stopped and
    /// the monitor busy for as long as it runs either way. The cost: while a
    /// `savevm` that hangs holds the monitor, Recovery Boot is refused, for up
    /// to this long. Only time the app runs counts; see `readUntilPrompt`.
    private static let lateSaveWait: TimeInterval = 600

    /// How long to wait for a monitor command that only has to answer.
    private static let monitorReplyDeadline: TimeInterval = 5

    /// The HMP prompt, and so the only reliable "that command has finished".
    private static let monitorPrompt = "(qemu)"

    /// Serializes everything that talks to the monitor.
    ///
    /// One socket, one command at a time, one reader. `savevm` holds it for as
    /// long as the snapshot takes. Commands come from more than one thread: a
    /// save runs on one of its own, while `monitorQueue` carries the console's
    /// resizes and anything else queued. Interleaved, the second command's
    /// prompt would be read as the first command finishing.
    private let monitorLock = NSLock()

    /// Where queued commands run, in the order they were asked for.
    ///
    /// Serial, so that one command cannot overtake another, and off the main
    /// thread, because the lock above may be held by a snapshot for minutes,
    /// and nothing on the main thread may wait that long.
    private let monitorQueue = DispatchQueue(label: "io.ara.tctish.monitor")

    /// How long to wait for the monitor when something else is using it, and
    /// for a recovery boot's replies.
    private static let monitorBusyDeadline: TimeInterval = 2

    /// How many replies the monitor still owes us.
    ///
    /// Every HMP command ends by printing a fresh prompt, so a command written
    /// without its reply being read leaves one sitting in the socket, and the
    /// next command to read finds it there and stops on it, returning before
    /// its output has arrived. Draining first only helps if the stray prompt
    /// has already landed, which is a race rather than a guarantee.
    ///
    /// Counting them means a reader can settle the debt by waiting rather than
    /// by hoping. Written and read only with `monitorLock` held.
    private var promptsOwed = 0

    /// Reads off the replies to commands nobody waited for.
    ///
    /// Call with `monitorLock` held, before sending a command and reading its
    /// reply.
    private func settleOutstandingPrompts() {
        while promptsOwed > 0 {
            // Counting each prompt, as one read can hold more than one reply.
            var response = ""
            guard readUntilPrompt(timeout: Self.monitorReplyDeadline, into: &response) else {
                Log.qemu.warn("the monitor owes \(promptsOwed) replies and isn't giving them")

                // The state of the connection is no longer known, so neither is the count. Whatever
                // arrives later is the next drain's problem rather than a debt that can never be
                // settled. Left standing, it would make every future command wait out this deadline
                // before doing anything.
                promptsOwed = 0
                return
            }

            promptsOwed -= min(promptsOwed, Self.prompts(in: response))
        }
    }

    /// Waits up to `limit` in all, by the clock, for every reply still owed,
    /// collecting them in `response`, and says whether they came. Counts each
    /// prompt in what arrives, as one read can hold more than one reply; on a
    /// timeout, the rest stay owed. Call with `monitorLock` held.
    private func awaitOwedPrompts(within limit: TimeInterval, into response: inout String) -> Bool {
        let owed = promptsOwed
        let deadline = Date().addingTimeInterval(limit)
        while Self.prompts(in: response) < owed {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, readUntilPrompt(timeout: remaining, into: &response) else {
                promptsOwed = owed - min(owed, Self.prompts(in: response))
                return false
            }
        }
        promptsOwed = 0
        return true
    }

    /// How many of the monitor's prompts are in `text`.
    private static func prompts(in text: String) -> Int {
        text.components(separatedBy: monitorPrompt).count - 1
    }

    /// Sends a command without waiting for it, in order behind any other.
    ///
    /// Goes through `runMonitorCommand` rather than writing directly, so that
    /// the reply is read and the socket is left just past a prompt; see
    /// `promptsOwed` for what happens when it isn't.
    private func sendMonitorCommand(_ command: String) {
        monitorQueue.async { [weak self] in
            self?.runMonitorCommand(command, timeout: Self.monitorReplyDeadline)
        }
    }

    /// Issues a monitor command and returns everything printed before the
    /// monitor came back to its prompt, or nil if it never did.
    ///
    /// Blocks for up to `timeout`, and `lateWait` more if given, so never call
    /// it from the main thread.
    ///
    /// With `lateWait`, a command that hasn't finished by `timeout` isn't given
    /// up on: `whenLate` is called, and the reply is waited for `lateWait`
    /// longer. That's for `savevm`, which often finishes after its deadline.
    /// `whenLate` means nothing without `lateWait`.
    @discardableResult
    private func runMonitorCommand(
        _ command: String, timeout: TimeInterval,
        lateWait: TimeInterval? = nil, whenLate: () -> Void = {}
    ) -> String? {
        monitorLock.lock()
        defer { monitorLock.unlock() }

        guard ensureMonitorConnection(), monitorSocket != nil else { return nil }

        // What earlier commands wrote and walked away from, waited for rather than hoped for.
        settleOutstandingPrompts()

        // And then whatever is left: a half-line, output belonging to a prompt already taken.
        // Anything still buffered here would otherwise be read as this command having finished
        // before it started.
        drainMonitor()

        guard writeMonitorCommand(command) else { return nil }

        var response = ""
        var answered = readUntilPrompt(timeout: timeout, into: &response)

        // Still connected, so only slow: keep what has come so far, and keep waiting.
        if !answered, let lateWait, monitorSocket != nil {
            whenLate()
            answered = readUntilPrompt(timeout: lateWait, into: &response)
        }

        guard answered else {
            Log.qemu.warn("monitor never came back to its prompt after '\(command)'")

            // After a late wait, a command whose monitor is still connected is still running, and
            // its prompt will come: it stays owed, so the next command waits for it rather than
            // taking it as the reply to itself. Otherwise the state of the connection is no longer
            // known.
            if lateWait == nil || monitorSocket == nil {
                promptsOwed = 0
            }
            return nil
        }

        promptsOwed -= 1
        return response
    }

    /// Writes one command. Call with `monitorLock` held.
    ///
    /// Records the reply as owed, whether or not this caller intends to read
    /// it: see `promptsOwed`.
    @discardableResult
    private func writeMonitorCommand(_ command: String) -> Bool {
        // One newline, not CR LF.
        let terminated = "\(command)\n"

        guard ensureMonitorConnection(), let monitorSocket else { return false }
        guard monitorSocket.write(Array(terminated.utf8)) == 0 else {
            // Gone, most likely; the next command connects again.
            self.monitorSocket = nil
            return false
        }

        promptsOwed += 1
        return true
    }

    /// Waits up to `milliseconds` for the monitor to have something to say, or
    /// to have closed, which a read then finds.
    private func monitorHasOutput(within milliseconds: UInt) -> Bool {
        guard let monitorSocket else { return false }

        var descriptor = pollfd(fd: monitorSocket.fd, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, Int32(min(milliseconds, UInt(Int32.max)))) > 0
    }

    /// Reads what the monitor has said: "" if it has said nothing after all,
    /// nil if it has closed, in which case the next command connects again.
    /// Call with the lock held.
    private func readMonitorChunk() -> String? {
        guard let monitorSocket else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes {
            read(monitorSocket.fd, $0.baseAddress, $0.count)
        }
        if count > 0 {
            return String(decoding: buffer[..<count], as: UTF8.self)
        }
        if count < 0, errno == EAGAIN || errno == EINTR {
            return ""
        }

        self.monitorSocket = nil
        return nil
    }

    /// Reads until the monitor's prompt comes round, and returns what was read,
    /// or nil if it never came. Call with the lock held.
    private func readUntilPrompt(timeout: TimeInterval) -> String? {
        var response = ""
        return readUntilPrompt(timeout: timeout, into: &response) ? response : nil
    }

    /// Reads into `response` until the monitor's prompt comes round, and says
    /// whether it did. What was read is kept either way, so that a caller can
    /// keep waiting. Call with the lock held.
    ///
    /// `timeout` counts only time this process ran. QEMU runs in it, so while
    /// iOS has the app suspended QEMU is stopped too, and a `savevm` it was in
    /// the middle of goes on once both are back: a return after ten minutes
    /// away hasn't used up any of the wait.
    private func readUntilPrompt(timeout: TimeInterval, into response: inout String) -> Bool {
        guard monitorSocket != nil else { return false }

        var counted: TimeInterval = 0
        var lastLook = ProcessInfo.processInfo.systemUptime

        while true {
            // At the end, one more look without waiting, for a reply that is there already.
            let remaining = timeout - counted
            let finalLook = remaining <= 0

            // Milliseconds, and sliced so that a long `savevm` still notices the deadline rather
            // than sitting in one enormous select.
            let slice = finalLook ? 0 : UInt(max(min(remaining, 1) * 1000, 1))
            let hasOutput = monitorHasOutput(within: slice)

            // A look takes its slice and a moment more; any longer, and the process was frozen.
            let now = ProcessInfo.processInfo.systemUptime
            counted += min(now - lastLook, Double(slice) / 1000 + Self.monitorLookSlack)
            lastLook = now

            guard hasOutput else {
                if finalLook { return false }
                continue
            }

            // Readable with nothing to give means the far end has gone.
            guard let chunk = readMonitorChunk() else {
                Log.qemu.warn("the monitor connection closed")
                return false
            }

            response += chunk

            if response.contains(Self.monitorPrompt) {
                return true
            }
        }
    }

    /// The most a look at the monitor counts beyond its slice; see
    /// `readUntilPrompt`.
    private static let monitorLookSlack: TimeInterval = 1

    /// The monitor's output, one line at a time.
    ///
    /// By `Character.isNewline` rather than by splitting on "\n", which is the
    /// same thing in most languages and is not the same thing here.
    private static func lines(of text: String) -> [Substring] {
        text.split(whereSeparator: \.isNewline)
    }

    /// A monitor reply flattened onto one line, for the log.
    private static func forLogging(_ reply: String) -> String {
        var content: [String] = []
        var echo: [String] = []

        for line in lines(of: reply) {
            let text =
                line
                .replacingOccurrences(
                    of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)

            guard !text.isEmpty else { continue }

            if line.unicodeScalars.contains("\u{1B}") {
                echo.append(text)
            } else {
                content.append(text)
            }
        }

        return (content.isEmpty ? echo : content).joined(separator: " | ")
    }

    /// Throws away whatever the monitor has already said. Call with the lock
    /// held.
    private func drainMonitor() {
        while monitorHasOutput(within: 0), let leftover = readMonitorChunk(), !leftover.isEmpty {}
    }

    /// Whether `tag` names a snapshot that could actually be loaded.
    private func snapshotIsLoadable(tag: String) -> Bool {
        guard let response = runMonitorCommand("info snapshots", timeout: Self.monitorReplyDeadline)
        else {
            Log.qemu.warn("session save: the monitor did not answer 'info snapshots'")
            return false
        }

        var inLoadableList = false
        var found = false

        for line in Self.lines(of: response) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if text.hasPrefix("List of snapshots present on all disks") {
                inLoadableList = true
                continue
            }
            if text.hasPrefix("List of partial") {
                inLoadableList = false
                continue
            }

            guard inLoadableList else { continue }

            // "ID  TAG  VM SIZE  DATE  VM CLOCK  ICOUNT", padded into columns.
            let fields = text.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2, fields[1] == tag {
                found = true
                break
            }
        }

        // The whole answer, verbatim, whenever the tag was not in the loadable list. There is no
        // second chance at this: the save runs as the app is being put away, and afterwards the
        // outcome alone cannot say which of the two lists the tag landed in or whether the machine
        // had a snapshot-capable disk at all, which is the case `hmp_info_snapshots` answers by
        // printing nothing and reporting to stderr.
        if !found {
            Log.qemu.warn(
                "session save: '\(tag)' is not in the loadable list; monitor said: "
                    + Self.forLogging(response))
        }

        return found
    }

    /// The tags QEMU says are on the disk, loadable or not.
    private func snapshotTagsOnDisk() -> [String]? {
        guard let response = runMonitorCommand("info snapshots", timeout: Self.monitorReplyDeadline)
        else {
            Log.qemu.warn("snapshots: the monitor did not answer 'info snapshots'")
            return nil
        }

        var tags: [String] = []
        var inList = false

        for line in Self.lines(of: response) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Only rows under one of the lists' headings. Before them comes the monitor's echo of
            // the command, and after them its prompt, and "info snapshots" has two words, which is
            // enough to pass for a row. Deleting what it passed for then does nothing at all, as
            // `delvm` says nothing about a tag that isn't there.
            if text.hasPrefix("List of") {
                inList = true
                continue
            }

            guard inList, !text.isEmpty, !text.hasPrefix("ID "),
                !text.hasPrefix(Self.monitorPrompt), !line.unicodeScalars.contains("\u{1B}")
            else {
                continue
            }

            // "ID  TAG  VM SIZE  DATE  VM CLOCK  ICOUNT", padded into columns.
            let fields = text.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2 {
                tags.append(String(fields[1]))
            }
        }

        return tags
    }

    /// The snapshot tags this app writes by itself.
    static let ownedSnapshotTags = ["instant_resume_a", "instant_resume_b", "instantboot"]

    /// Clears up snapshots that describe a machine this build no longer makes.
    ///
    /// Not only a QEMU upgrade: the epoch also covers the machine's shape and
    /// the bundled guest kernel, so a new kernel or a changed device list lands
    /// here too. See `VmSnapshots`.
    ///
    /// Call off the main thread, once Linux is up: it talks to the monitor, and
    /// `savevm`-adjacent commands want a machine that has finished booting.
    func discardPreUpgradeSnapshots() {
        guard VmSnapshots.changedSinceLastBoot else { return }

        // Once per process. Linux comes up again after every recovery boot, so the notification
        // that brings us here is not as once-only as its comment suggests.
        guard
            Self.discardLock.withLock({
                defer { Self.discardStarted = true }
                return !Self.discardStarted
            })
        else { return }

        // Both bail-outs below mean "try again", and a slot held by a run that gave up is a slot
        // that stops this launch ever retrying.
        var completed = false
        defer {
            if !completed {
                Self.discardLock.withLock { Self.discardStarted = false }
            }
        }

        guard Self.snapshotWorkLock.try() else {
            Log.qemu.note("snapshots: a save is running; leaving the cleanup for next boot")
            return
        }
        defer { Self.snapshotWorkLock.unlock() }

        // No answer means no information. Recording the epoch here would mark the cleanup done on
        // the strength of a timeout: the snapshots would stay on the disk for ever, and Boot From
        // Snapshot would still be pointed at one of them when the next launch stopped forcing a
        // cold boot.
        guard let onDisk = snapshotTagsOnDisk() else {
            Log.qemu.warn("snapshots: could not read the disk; leaving the cleanup for next boot")
            return
        }

        var discarded: [String] = []

        for tag in onDisk where Self.ownedSnapshotTags.contains(tag) {
            guard let reply = runMonitorCommand("delvm \(tag)", timeout: Self.monitorReplyDeadline)
            else {
                Log.qemu.warn("snapshots: 'delvm \(tag)' did not answer; leaving it")
                continue
            }

            if let failure = Self.monitorError(in: reply) {
                Log.qemu.warn("snapshots: 'delvm \(tag)' refused: \(failure)")
                continue
            }

            discarded.append(tag)
        }

        // Nothing points at a snapshot that is gone.
        //
        // Only if it still names one of the stale ones. After a migration-stream change the pointer
        // is useless even where the delete failed, but it is only ours to clear if it names
        // something that was on the disk when we looked.
        let pointer = getResumeImage()
        if !pointer.isEmpty && onDisk.contains(pointer) {
            setResumeImage(tag: "")
        }

        let theirs = onDisk.filter { !Self.ownedSnapshotTags.contains($0) }

        // Stop Boot From Snapshot pointing at something this QEMU cannot read.
        //
        // The forced cold boot in `getBootImageName` only covers the launch that does the
        // discarding. Once the epoch is recorded the override lapses, and the *next* launch would
        // hand `-loadvm` a snapshot from the old QEMU.
        var unpointed: String?
        if AppSetting.resumeBehavior.string == "snapshot_boot" {
            let named = AppSetting.bootSnapshot.string
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !named.isEmpty && onDisk.contains(named) {
                AppSetting.resumeBehavior.set("recovery_boot")
                unpointed = named
                Log.qemu.note(
                    "snapshots: boot mode moved off '\(named)'; it predates this build")
            }
        }

        // Only now. Until this lands the next launch tries again, which is what should happen if
        // the monitor was not answering.
        VmSnapshots.recordBooted()
        completed = true

        guard !discarded.isEmpty || !theirs.isEmpty || unpointed != nil else {
            Log.qemu.note("snapshots: nothing left by an earlier build")
            return
        }

        Log.qemu.note(
            "snapshots: discarded \(discarded.joined(separator: ", ")); "
                + "kept \(theirs.count) of someone else's")

        var body =
            "tctiSH has been updated, and sessions saved by the previous version cannot be "
            + "resumed. Linux started fresh. Your files and installed packages are untouched."

        if !theirs.isEmpty {
            let plural = theirs.count == 1 ? "snapshot" : "snapshots"
            let verb = theirs.count == 1 ? "was" : "were"
            body +=
                " \(theirs.count) \(plural) you named yourself ("
                + theirs.joined(separator: ", ") + ") \(verb) left alone, but cannot be booted "
                + "from."
        }

        if let unpointed {
            body +=
                " Startup was switched to Recovery Boot, because it was set to boot from "
                + "'\(unpointed)'."
        }

        LocalAlert.post(
            title: "Saved session could not be restored",
            body: body,
            id: Self.staleSnapshotAlertId)
    }

    /// Guards `discardPreUpgradeSnapshots` against running twice over.
    private static let discardLock = NSLock()
    private static var discardStarted = false

    /// Held for the whole of a session save, or of a stale-snapshot discard.
    ///
    /// `monitorLock` serializes individual commands; this serializes the
    /// sequences they belong to. A save picks a rotation tag, writes it, checks
    /// it is loadable, and only then points `resume_image` at it. A discard
    /// deletes tags and clears that pointer. Both sides use the name
    /// `instant_resume_a`, so interleaving them means deleting a snapshot from
    /// underneath the `savevm` that is still writing it.
    ///
    /// The discard takes it with `try()` and gives up if a save holds it, which
    /// is why it doesn't record the epoch on that path.
    private static let snapshotWorkLock = NSLock()

    /// Identifier for the notification above, so it replaces rather than
    /// stacks.
    private static let staleSnapshotAlertId = "stale-snapshot"

    /// Get the next 'instant resume' file image. This ensures we never
    /// overwrite an image until our save is complete.
    private func getNextInstantResumeTag() -> String {
        let current = getImageProperty(
            diskName: disk, property: "resume_image", defaultValue: "b")

        if current.last == "b" {
            return "instant_resume_a"
        } else {
            return "instant_resume_b"
        }
    }

    /// Starts or resumes the tctiSH instance's execution.
    func pause() {
        sendMonitorCommand("halt")
    }

    /// Starts or resumes the tctiSH instance's execution.
    func resume() {
        sendMonitorCommand("cont")
    }

    /// Where QEMU listens for the app's connection to the console `device`.
    static func consoleSocketPath(_ device: String) -> String {
        socketPath(device)
    }

    /// Where QEMU listens for the app's connection to the guest agent.
    static let agentSocketPath = socketPath("agent")

    /// Where QEMU listens for the app's connection to `tctictl`'s port.
    static let controlSocketPath = socketPath("ctl")

    /// Where QEMU keeps what a character device sends, by name. Beside the
    /// sockets, and made afresh at every launch, as they are.
    static func logPath(_ name: String) -> String {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).log").path
    }

    /// Where QEMU listens for one of the app's connections to it, by name.
    ///
    /// The names in use are `monitor`, `agent`, `ctl`, `hvc0` to `hvc11`,
    /// `ttyS0` and `hmp`.
    ///
    /// In the app's tmp folder, which the Files app doesn't show, rather than
    /// in Documents, which it does. A socket deleted there leaves QEMU unable
    /// to take a connection again until the next launch, and a folder made
    /// under its name leaves QEMU unable to start at all. iOS may empty tmp
    /// while the app isn't running, which is harmless: QEMU makes its sockets
    /// afresh at every launch.
    ///
    /// Names stay short. A Unix socket's path has to fit in 104 bytes with its
    /// terminating NUL, and on a device the folder's path alone is 89 of them.
    static func socketPath(_ name: String) -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name).sock").path

        if path.utf8.count >= MemoryLayout.size(ofValue: sockaddr_un().sun_path) {
            Log.qemu.fail("socket path is too long to listen at: \(path)")
        }
        return path
    }

    /// Removes the sockets that earlier builds made in Documents, where the
    /// Files app showed them. Only sockets: anything else by those names is
    /// someone's file.
    private static func removeSocketsFromDocuments() {
        for name in ["monitor", "hvc0", "agent"] {
            let path = getDatastoreURL(name, fileExtension: "socket", create: false).path
            let type = try? FileManager.default.attributesOfItem(atPath: path)[.type]
            guard type as? FileAttributeType == .typeSocket else { continue }

            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Sets the size of the console `device`, which Linux gives its tty.
    ///
    /// Sent in order behind any other monitor command, and only the latest size
    /// for each console, so that a rotation's run of sizes costs one command
    /// for each console rather than one for each size.
    ///
    /// `redrawing` has the programs on the console draw their screens again,
    /// for a terminal that has lost what they drew: the console is made a row
    /// shorter first, so that the size changes, and the tty sends SIGWINCH,
    /// even when the size was already right.
    func resizeConsole(_ device: String, cols: Int, rows: Int, redrawing: Bool = false) {
        consoleSizesLock.lock()
        let sending = !consoleSizes.isEmpty
        let redraw = redrawing || consoleSizes[device]?.redraw == true
        consoleSizes[device] = (cols, rows, redraw)
        consoleSizesLock.unlock()

        guard !sending else { return }
        monitorQueue.async { [weak self] in
            guard let self else { return }
            consoleSizesLock.lock()
            let sizes = consoleSizes
            consoleSizes.removeAll()
            consoleSizesLock.unlock()

            let redrawn = sizes.filter { $0.value.redraw && $0.value.rows > 1 }
            for (device, size) in redrawn {
                runMonitorCommandCleanly(
                    "console_resize \(device) \(size.cols) \(size.rows - 1)", purpose: "console")
            }

            // Linux applies a size from work it schedules, which takes whatever size is latest when
            // it runs. Both sizes at once would look like no change at all, and signal nothing. One
            // wait for every console, so that opening several at once doesn't hold the monitor up
            // for each.
            if !redrawn.isEmpty {
                Thread.sleep(forTimeInterval: 0.3)
            }

            for (device, size) in sizes {
                runMonitorCommandCleanly(
                    "console_resize \(device) \(size.cols) \(size.rows)", purpose: "console")
            }
        }
    }

    /// The sizes `resizeConsole` has yet to send, by console. A send is on its
    /// way whenever this isn't empty.
    private var consoleSizes: [String: (cols: Int, rows: Int, redraw: Bool)] = [:]
    private let consoleSizesLock = NSLock()

    /// Resolves a saved bookmark and starts security-scoped access to its
    /// folder, so that QEMU's 9p can follow a link to it. A stale bookmark is
    /// replaced with one made while access is held, which comes back as
    /// `bookmark`; if that can't be made, the old one, which still resolved,
    /// comes back instead.
    private func setupMountPermissions(bookmarkData: Data) -> (url: URL, bookmark: Data)? {
        var isStale = false
        guard
            let hostPath = try? URL(
                resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
        else {
            return nil
        }
        _ = hostPath.startAccessingSecurityScopedResource()

        guard isStale else { return (hostPath, bookmarkData) }
        do {
            return (hostPath, try hostPath.bookmarkData())
        } catch {
            Log.qemu.warn("mount: couldn't replace a stale bookmark: \(error)")
            return (hostPath, bookmarkData)
        }
    }

    /// Sets up a given host URL for mounting, and returns its name in the
    /// shared folder, or why it couldn't.
    ///
    /// With `persistent`, the folder is remembered for this disk, so that the
    /// next launch gets access to it again. A name shared before keeps its
    /// slot, with the new bookmark: picking a folder again is how one that can
    /// no longer be reached comes back.
    func mount(
        bookmarkData: Data, interfaceId: String? = nil, predefinedTag: String? = nil,
        persistent: Bool = true
    ) -> Result<String, GuestRefusal> {
        let tag = predefinedTag ?? generateMountTag(length: 6)
        let id = interfaceId ?? generateMountTag(length: 6)

        guard let (hostPath, bookmark) = setupMountPermissions(bookmarkData: bookmarkData) else {
            return .failure(GuestRefusal("the folder can't be reached any more; pick it again"))
        }

        // Mount it, and remember it only if that worked.
        let mounted = mount(hostPath: hostPath, interfaceId: id, predefinedTag: tag)
        if case .success = mounted, persistent {
            Self.imageStoreLock.lock()
            defer { Self.imageStoreLock.unlock() }

            var mounts = getPersistentMounts()
            if mounts.contains(where: { $0.mount_tag == tag }) {
                for index in mounts.indices where mounts[index].mount_tag == tag {
                    mounts[index].bookmark = bookmark
                }
            } else {
                mounts.append(DiskMountInfo(bookmark: bookmark, fsdev_tag: id, mount_tag: tag))
            }
            storeMountSlots(mounts)
        }
        return mounted
    }

    /// Sets up a given host URL for mounting.
    func mount(
        hostPath: URL, interfaceId: String? = nil, predefinedTag: String? = nil
    ) -> Result<String, GuestRefusal> {
        return mount(
            hostPath: hostPath.path, interfaceId: interfaceId, predefinedTag: predefinedTag)
    }

    /// Sets up a given host path for mounting: links it into the shared folder
    /// as `predefinedTag` or a new name, which the guest sees under `/ios_host`
    /// because QEMU's 9p follows the link. Returns the name, or why it
    /// couldn't.
    ///
    /// Replaces nothing but a link to a folder that can't be reached, and only
    /// when no other disk remembers a share by that name: that disk's folder
    /// may only look unreachable because this launch has no access to it. A
    /// link to the same folder is reused. A link to another folder is refused,
    /// since its mounts would start showing the new one, and so is a real file
    /// or folder by that name, which is the person's.
    func mount(
        hostPath: String, interfaceId: String? = nil, predefinedTag: String? = nil
    ) -> Result<String, GuestRefusal> {
        let tag = predefinedTag ?? generateMountTag(length: 6)
        let link = shareLink(tag)
        let files = FileManager.default

        // `destinationOfSymbolicLink` first, not `fileExists`, which follows links: what matters is
        // what's at the name itself. A link to a folder that can't be reached any more shares
        // nothing, so it's replaced; that's how a folder that moved, or lost its access, is picked
        // again under the same name.
        //
        // Finding where the link leads, and whether its folder answers, both reach into a file
        // provider, so they get `providerLimit`. A folder that doesn't answer by then counts as
        // unreachable only for a name this disk remembers, which is how one on a provider gone for
        // good is picked again; a link by any other name is left alone.
        let before = try? files.destinationOfSymbolicLink(atPath: link)
        if before != nil {
            let found = Self.withinProviderLimit(key: "link \(tag)") { [self] in
                (
                    same: shareLinkTarget(tag) == Self.resolved(hostPath),
                    answers: files.fileExists(atPath: link)
                )
            }
            if found?.same == true {
                return .success(tag)
            }
            guard found?.answers != true else {
                return .failure(GuestRefusal("'\(tag)' already shares another folder"))
            }
            guard found != nil || getPersistentMounts().contains(where: { $0.mount_tag == tag })
            else {
                return .failure(
                    GuestRefusal(
                        "'\(tag)' already shares a folder that isn't answering; try again, or use "
                            + "another name"))
            }
            guard !isRememberedElsewhere(tag) else {
                return .failure(GuestRefusal("another disk shares a folder as '\(tag)'"))
            }
        }

        // The rest under the store's lock, which `relinkShare` holds as it changes a link, and only
        // if the link is still what was looked at.
        Self.imageStoreLock.lock()
        defer { Self.imageStoreLock.unlock() }
        guard (try? files.destinationOfSymbolicLink(atPath: link)) == before else {
            return .failure(GuestRefusal("'\(tag)' changed meanwhile; try again"))
        }
        if before != nil {
            try? files.removeItem(atPath: link)
        }
        if (try? files.attributesOfItem(atPath: link)) != nil {
            return .failure(GuestRefusal("/ios_host already has a file or folder called '\(tag)'"))
        }

        do {
            try files.createSymbolicLink(atPath: link, withDestinationPath: hostPath)
        } catch {
            return .failure(
                GuestRefusal("couldn't share it as '\(tag)': \(error.localizedDescription)"))
        }
        return .success(tag)
    }

    /// Generates a random tag suitable for use in mounting.
    private func generateMountTag(length: Int = 12) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return "m" + String((0..<length).map { _ in letters.randomElement()! })
    }

    /// The path of the shared folder's entry `name`, which is a link for a
    /// shared folder.
    private func shareLink(_ name: String) -> String {
        getSharedFolder().appendingPathComponent(name, isDirectory: false).path
    }

    /// Where the shared folder's link `name` leads, with links on the way
    /// resolved, or nil if there's no link by that name.
    private func shareLinkTarget(_ name: String) -> String? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: shareLink(name)))
            .map(Self.resolved)
    }

    /// `path` with its links resolved, to compare where two paths lead.
    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: File providers

    /// How long anything that waits on a folder's file provider waits for it.
    private static let providerLimit: TimeInterval = 2

    /// Holds the result of a call into a file provider until
    /// `withinProviderLimit` reads it, if the call finished in time.
    private final class ProviderResult<T> {
        var value: T?
    }

    /// Waits at most `providerLimit` for `work`, a call into a file provider,
    /// and returns its result, or nil if it didn't finish in time. An offline
    /// provider can keep such a call waiting for tens of seconds. The work
    /// carries on, on another thread, and its result is dropped; until it ends,
    /// another call with the same `key` returns nil at once, so that a folder
    /// that never answers ties up one thread, not one per question.
    private static func withinProviderLimit<T>(key: String, _ work: @escaping () -> T) -> T? {
        guard providerCallsLock.withLock({ providerCalls.insert(key).inserted }) else {
            return nil
        }

        let result = ProviderResult<T>()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work()
            providerCallsLock.withLock {
                result.value = value
                providerCalls.remove(key)
            }
            finished.signal()
        }

        guard finished.wait(timeout: .now() + providerLimit) == .success else {
            Log.qemu.warn(
                "mount: no answer from a folder's provider (\(key)) within \(Int(providerLimit))s")
            return nil
        }
        return providerCallsLock.withLock { result.value }
    }

    /// The calls into file providers still running, by key; see
    /// `withinProviderLimit`. The lock also covers each `ProviderResult`'s
    /// value, written on the worker's thread and read on the caller's.
    private static var providerCalls: Set<String> = []
    private static let providerCallsLock = NSLock()

    // MARK: Mount slots

    /// The image properties that hold a disk's mount data: `disk_mount_0`,
    /// `disk_mount_1` and on.
    private static let mountSlotPrefix = "disk_mount_"

    /// The mount data saved for `disk`, or the running disk, in slot order, so
    /// that its shared folders can be mounted again. Slots are filled from 0
    /// with no gaps; a slot that can't be read is left out, and goes at the
    /// next `storeMountSlots`.
    private func getPersistentMounts(disk: String? = nil) -> [DiskMountInfo] {
        let image = Self.imageStore()[disk ?? self.disk] ?? [:]
        var mounts: [DiskMountInfo] = []
        var slot = 0
        while let serialized = image[Self.mountSlotPrefix + String(slot)] {
            if let info = try? JSONDecoder().decode(DiskMountInfo.self, from: Data(serialized.utf8))
            {
                mounts.append(info)
            }
            slot += 1
        }
        return mounts
    }

    /// Stores `mounts` as this disk's slots, from 0, in one write, in place of
    /// all of them, so that the app being killed partway can't leave one share
    /// in two slots.
    private func storeMountSlots(_ mounts: [DiskMountInfo]) {
        Self.imageStoreLock.lock()
        defer { Self.imageStoreLock.unlock() }

        var images = Self.imageStore()
        var image = (images[disk] ?? [:]).filter { !$0.key.hasPrefix(Self.mountSlotPrefix) }
        for (slot, info) in mounts.enumerated() {
            let serializedData = try! JSONEncoder().encode(info)
            image[Self.mountSlotPrefix + String(slot)] = String(
                decoding: serializedData, as: UTF8.self)
        }
        images[disk] = image
        UserDefaults.standard.set(images, forKey: "images")
    }

    /// Whether a disk other than this one remembers a share called `name`.
    private func isRememberedElsewhere(_ name: String) -> Bool {
        Self.imageStore().keys.contains { other in
            other != disk && getPersistentMounts(disk: other).contains { $0.mount_tag == name }
        }
    }

    // MARK: Shares at launch

    /// Gets access again to every folder this disk remembers, and points each
    /// link in the shared folder at where its folder is now. Each runs on a
    /// thread of the global queue, so that none waits on another and the launch
    /// waits on none: a folder on an offline provider, such as a network share
    /// whose server has gone, can keep these calls waiting for tens of seconds.
    /// Until one is done, its link leads where it led at the last launch, which
    /// at worst is nowhere.
    private func recreatePersistentMounts() {
        for mount in self.getPersistentMounts() {
            launchAccess.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { launchAccess.leave() }
                let started = Date()
                recreatePersistentMount(mount_info: mount)

                // Slower than anything that waits on a provider would wait.
                let took = -started.timeIntervalSinceNow
                if took > Self.providerLimit {
                    Log.qemu.warn(
                        String(
                            format: "mount: '%@' took %.1fs to reach", mount.mount_tag, took))
                }
            }
        }
    }

    /// The launch's `recreatePersistentMounts`, until each folder is done.
    private let launchAccess = DispatchGroup()

    /// Waits a little, up to `providerLimit`, for the launch to get access to
    /// the folders again: a guest that boots fast can ask about one before a
    /// slow provider has let the app back in, and would find it unreachable.
    private func waitForLaunchAccess() {
        _ = launchAccess.wait(timeout: .now() + Self.providerLimit)
    }

    /// Re-creates a mount point on image startup: gets access to the folder
    /// again, and points its link in the shared folder at where the folder is
    /// now, which can move between launches. The guest mounts it again from
    /// there at boot.
    private func recreatePersistentMount(mount_info: DiskMountInfo) {
        let tag = mount_info.mount_tag
        guard let (hostPath, bookmark) = setupMountPermissions(bookmarkData: mount_info.bookmark)
        else {
            Log.qemu.warn("mount: '\(tag)' can't be reached; it must be picked again")
            return
        }
        if bookmark != mount_info.bookmark {
            replaceBookmark(ofShare: tag, mount_info.bookmark, with: bookmark)
        }
        relinkShare(tag: tag, to: hostPath.path)
    }

    /// Replaces the bookmark the share `tag` has in its slot, if it is still
    /// `old`: by name rather than by slot number, which a forget changes.
    private func replaceBookmark(ofShare tag: String, _ old: Data, with new: Data) {
        Self.imageStoreLock.lock()
        defer { Self.imageStoreLock.unlock() }

        var mounts = getPersistentMounts()
        for index in mounts.indices
        where mounts[index].mount_tag == tag && mounts[index].bookmark == old {
            mounts[index].bookmark = new
        }
        storeMountSlots(mounts)
    }

    /// Points the shared folder's link `tag` at `hostPath`, if it points
    /// somewhere else. Only a link is replaced: a real file or folder by that
    /// name is the person's. A missing link isn't made again: forgetting a
    /// share removes its link and its slot together, so a slot with no link
    /// means the link was deleted, or the slot is from an older build.
    ///
    /// Unlike `mount(hostPath:)`, which refuses to point a name at another
    /// folder, this follows the same folder, saved in the slot, to where it is
    /// now.
    private func relinkShare(tag: String, to hostPath: String) {
        // Comparing where the paths lead reaches into the folders' providers, and can take long.
        let files = FileManager.default
        let link = shareLink(tag)
        guard let before = try? files.destinationOfSymbolicLink(atPath: link),
            Self.resolved(before) != Self.resolved(hostPath)
        else {
            return
        }

        // A new link put in place by a rename, so that a failure leaves the old one rather than
        // none, which would never be made again. Made in the app's temporary folder, on the same
        // volume, so that it can't collide with anything in the shared folder.
        let newLink = files.temporaryDirectory.appendingPathComponent("relink-\(UUID().uuidString)")
            .path
        defer { try? files.removeItem(atPath: newLink) }

        // Under the store's lock, which `forgetShare` and `mount(hostPath:)` hold as they change
        // links, and only if nothing has changed the link meanwhile: a forget removes it, and a
        // folder picked again points it elsewhere, which this mustn't undo.
        Self.imageStoreLock.lock()
        defer { Self.imageStoreLock.unlock() }
        guard getPersistentMounts().contains(where: { $0.mount_tag == tag }),
            (try? files.destinationOfSymbolicLink(atPath: link)) == before
        else {
            Log.qemu.note("mount: '\(tag)' changed while it was being found; leaving it")
            return
        }
        do {
            try files.createSymbolicLink(atPath: newLink, withDestinationPath: hostPath)
            guard rename(newLink, link) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Log.qemu.warn("mount: couldn't point '\(tag)' at its folder again: \(error)")
        }
    }

    // MARK: Remembered shares

    /// What this disk remembers of a folder shared under a name, for `tctictl`:
    /// whether mounting it again can skip the picker.
    enum ShareState: String {
        /// This disk's share, and the guest can reach it: the link at the name
        /// leads to the folder the slot holds, which is there and is a folder.
        case reachable

        /// This disk remembers the name, but the folder can't be reached, or
        /// the link at the name no longer leads to it.
        case unreachable

        /// Not a name this disk remembers.
        case unknown
    }

    /// What this disk remembers of the folder shared as `name`.
    func shareState(_ name: String) -> ShareState {
        waitForLaunchAccess()
        guard let info = rememberedMounts().first(where: { $0.mount_tag == name }) else {
            return .unknown
        }
        return isReachable(info) ? .reachable : .unreachable
    }

    /// A share this disk remembers, for `tctictl mounts`.
    struct RememberedShare: Encodable {
        let name: String
        let mountpoints: [String]
        let reachable: Bool
    }

    /// The shares this disk remembers, in the order they were first mounted.
    func rememberedShares() -> [RememberedShare] {
        waitForLaunchAccess()
        return rememberedMounts().map {
            RememberedShare(
                name: $0.mount_tag, mountpoints: $0.mountpoints ?? [], reachable: isReachable($0))
        }
    }

    /// Adds `mountpoint` to where the guest mounts the share `name`, so that
    /// the next boot mounts it there again. Each mountpoint belongs to the
    /// share mounted there last, so this also takes it off any other share this
    /// disk remembers.
    func recordMountpoint(_ mountpoint: String, forShare name: String) -> Result<
        Void, GuestRefusal
    > {
        Self.imageStoreLock.lock()
        defer { Self.imageStoreLock.unlock() }

        var mounts = getPersistentMounts()
        guard mounts.contains(where: { $0.mount_tag == name }) else {
            return .failure(Self.notRemembered(name))
        }
        for index in mounts.indices {
            let known = (mounts[index].mountpoints ?? []).filter { $0 != mountpoint }
            mounts[index].mountpoints =
                mounts[index].mount_tag == name ? known + [mountpoint] : known
        }
        storeMountSlots(mounts)
        return .success(())
    }

    /// Forgets the share `name` on this disk: its slot, and its link in the
    /// shared folder unless another disk remembers the name too.
    func forgetShare(_ name: String) -> Result<Void, GuestRefusal> {
        Self.imageStoreLock.lock()
        defer { Self.imageStoreLock.unlock() }

        let mounts = getPersistentMounts()
        guard mounts.contains(where: { $0.mount_tag == name }) else {
            return .failure(Self.notRemembered(name))
        }

        // Every slot by that name, as older builds could save one twice.
        storeMountSlots(mounts.filter { $0.mount_tag != name })
        removeShareLinkIfUnused(name)
        return .success(())
    }

    /// Forgets every share this disk remembers, as for a disk just created from
    /// the empty image: what was mounted where belonged to the disk it
    /// replaces. The folders themselves are untouched, and can be picked again.
    private func forgetAllShares() {
        Self.imageStoreLock.lock()
        defer { Self.imageStoreLock.unlock() }

        let names = Set(getPersistentMounts().map(\.mount_tag))
        guard !names.isEmpty else { return }
        storeMountSlots([])
        for name in names where ConfigServer.isShareName(name) {
            removeShareLinkIfUnused(name)
        }
        Log.qemu.note("mount: a new disk, so its \(names.count) remembered folders are forgotten")
    }

    /// Removes the shared folder's link `name` unless another disk remembers a
    /// share by that name, since all disks use the same shared folder. Only a
    /// link: a real file or folder by that name is the person's.
    private func removeShareLinkIfUnused(_ name: String) {
        // A link, read without following it: the folder's provider may not be answering.
        let link = shareLink(name)
        guard !isRememberedElsewhere(name),
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil
        else { return }
        try? FileManager.default.removeItem(atPath: link)
    }

    /// The slots this disk remembers that `tctictl` can name. Slots saved by
    /// builds that named a share by its guest path (`/root/docs`) are left out:
    /// no such name can be mounted or forgotten. `recordMountpoint` and
    /// `forgetShare` need no filter, as the config server checks their names.
    private func rememberedMounts() -> [DiskMountInfo] {
        getPersistentMounts().filter { ConfigServer.isShareName($0.mount_tag) }
    }

    private static func notRemembered(_ name: String) -> GuestRefusal {
        GuestRefusal("'\(name)' isn't a folder this disk remembers")
    }

    /// Whether the link at a remembered share's name leads to the folder its
    /// bookmark names, and that is there and is a folder, found out within
    /// `providerLimit`: one whose provider doesn't answer by then can't be
    /// reached. On the config server's queue, which a provider that never
    /// answers would otherwise hold up for every request.
    private func isReachable(_ info: DiskMountInfo) -> Bool {
        // By the bookmark as well as the name, so that a folder picked again under the name is
        // asked about afresh while a question about the old one is still stuck.
        Self.withinProviderLimit(key: "reach \(info.mount_tag) \(info.bookmark.hashValue)") {
            [self] in
            folderAnswers(info)
        } ?? false
    }

    /// `isReachable`, however long the folder's provider takes.
    private func folderAnswers(_ info: DiskMountInfo) -> Bool {
        var isStale = false
        guard
            let folder = try? URL(
                resolvingBookmarkData: info.bookmark, bookmarkDataIsStale: &isStale),
            shareLinkTarget(info.mount_tag) == Self.resolved(folder.path)
        else {
            return false
        }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: shareLink(info.mount_tag), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Fetches the path to the QEMU framework appropriate for this environment.
    /// The one QEMU there is, which holds both TCTI and native code and is told
    /// which to start on.
    private func getAppropriateQemuFramework() -> URL {
        var frameworkURL = Bundle.main.bundleURL
        frameworkURL.appendPathComponent("Frameworks", isDirectory: true)

        let qemuName = "qemu-x86_64-softmmu"

        frameworkURL.appendPathComponent("\(qemuName).framework", isDirectory: true)
        frameworkURL.appendPathComponent(qemuName)

        return frameworkURL
    }

    /// Gets the boot image used for the user-selected boot mode.
    private func getBootImageName(forceRecoveryBoot: Bool) -> String? {
        var mode = UserDefaults.standard.string(forKey: "resume_behavior")

        // If we're forcing a recovery boot, override the read mode.
        if forceRecoveryBoot {
            mode = "recovery_boot"
        }

        // If our memory value has changed, force a recovery boot.
        if memoryValueChanged() {
            mode = "recovery_boot"
        }

        // Same when the machine itself has moved: a newer QEMU's migration stream, a changed device
        // list or topology, or a different guest kernel. Every snapshot on the disk describes the
        // old machine, including one someone typed into Boot From Snapshot, and loading any of them
        // fails *after* device state has been partly restored.
        if VmSnapshots.changedSinceLastBoot {
            mode = "recovery_boot"
        }

        switch mode {
        case "persistent_boot":
            let resume_image = getResumeImage()
            if isFirstBoot() {
                return nil
            }

            // The machine-wide checks above only notice a change on the launch after it, and only
            // for this disk. This one travels with the session, so it holds for any disk however
            // long ago things changed. A session saved before stamps existed has none, and cold
            // boots once.
            //
            // The pointer is left alone, as a mismatch is never resumed and the next save replaces
            // it anyway.
            let saved = getResumeStamp()
            let wanted = Self.wantedStamp
            guard saved == wanted else {
                Log.qemu.note(
                    "resume: '\(resume_image)' was saved by a different machine "
                        + "(\(saved.isEmpty ? "unstamped" : saved), now \(wanted)); cold booting")
                return nil
            }

            return resume_image
        case "snapshot_boot":
            // Blank means no snapshot was named, which is a cold boot rather than a request to
            // resume from one called "". QEMU survives being asked for that but there's nothing to
            // say.
            let snapshot = UserDefaults.standard.string(forKey: "boot_snapshot")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (snapshot?.isEmpty ?? true) ? nil : snapshot
        case "recovery_boot":
            forgetSession(because: "this launch boots Linux afresh")
            return nil
        case "clean_boot":
            return "instantboot"
        default:
            Log.qemu.fail("no such boot mode \(String(describing: mode)) in the settings pane")
            exit(1);
        }
    }

    /// Returns a string indicating the currently used disc name.
    ///
    /// A blank name reads as "not set" rather than as a name. The settings
    /// screen offers this as a text field with a clear button, and an emptied
    /// one is stored as "" which shadows the registered default, so the
    /// fallback below would never be reached and the session would silently
    /// move to a disk called ".qcow".
    private static func diskNameSetting() -> String {
        let stored = UserDefaults.standard.string(forKey: "disk_name")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let stored, !stored.isEmpty else { return "disk" }
        return stored
    }

    /// Returns true iff the memory setting has changed since the last boot.
    func memoryValueChanged() -> Bool {
        return VmMemory.changedSinceLastBoot
    }

    /// Returns the URL to a qcow image that will acts as our persistent store.
    private func getPersistentStore() -> URL {
        let diskName = disk

        // Figure out where our persistent store would be located.
        let targetURL = getDatastoreURL(diskName, fileExtension: "qcow")

        // If it doesn't exist, create a new copy based on our empty disk.
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            let emptyDiskURL = Bundle.main.url(forResource: "empty", withExtension: "qcow")
            try! FileManager.default.copyItem(at: emptyDiskURL!, to: targetURL)

            // Reset the startup to base instant-boot, since we now have a new disk, and forget the
            // folders the old disk mounted: a disk of the same name may have been deleted.
            setResumeImage(tag: "instantboot")
            forgetAllShares()
        }

        Self.removeAbandonedCompactions(of: targetURL)

        return targetURL
    }

    /// Returns the URL of a folder that can be used as the root of our iOS
    /// mounts. Typically mounted as `/ios_host`.
    static func getSharedFolder() -> URL {
        // Figure out where our persistent store would be located.
        let targetURL = getDatastoreURL("SharedFolder", fileExtension: "d")

        // If it doesn't exist, create a new copy based on our empty disk.
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            try! FileManager.default.createDirectory(
                at: targetURL, withIntermediateDirectories: false)
        }

        return targetURL
    }

    /// Returns the URL of a folder that can be used as the root of our iOS
    /// mounts. Typically mounted as `/ios_host`.
    func getSharedFolder() -> URL {
        return QEMUInterface.getSharedFolder()
    }

    /// Removes `last_cwd.dat` from the shared folder, where the Files app shows
    /// it. Builds that reached the guest over SSH kept the shell's directory in
    /// it, so that a new shell could start there; nothing uses it now.
    func clearLastCWDFile() {
        let cwdFile = QEMUInterface.getSharedFolder().appendingPathComponent("last_cwd.dat")

        // If we have a cwdfile, delete it.
        if FileManager.default.fileExists(atPath: cwdFile.path) {
            try? FileManager.default.removeItem(at: cwdFile)
        }
    }

    /// Retreives the path to a file in our local data store. Currently fetches
    /// a path in the per-app 'Documents' directory; but this may change.
    private static func getDatastoreURL(_ name: String, fileExtension: String, create: Bool = true)
        -> URL
    {

        // Figure out where our persistent store would be located.
        var targetURL = try! FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "\(name).\(fileExtension)"),
            create: create)

        // Scult our filename so it ends in "ab_status.conf".
        targetURL.appendPathComponent(name)
        targetURL.appendPathExtension(fileExtension)

        return targetURL
    }

    /// Retreives the path to a file in our local data store. Currently fetches
    /// a path in the per-app 'Documents' directory; but this may change.
    private func getDatastoreURL(_ name: String, fileExtension: String, create: Bool = true) -> URL
    {
        QEMUInterface.getDatastoreURL(name, fileExtension: fileExtension, create: create)
    }

    /// The disk-image metadata store: each disk's properties, by its name.
    private static func imageStore() -> [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: "images") as? [String: [String: String]] ?? [:]
    }

    /// Returns a property from the disk-image metadata store.
    private func getImageProperty(diskName: String, property: String, defaultValue: String)
        -> String
    {
        Self.imageStore()[diskName]?[property] ?? defaultValue
    }

    /// Sets a property from the disk-image metadata store.
    private func setImageProperty(diskName: String, property: String, value: String) {
        setImageProperties(diskName: diskName, [property: value])
    }

    /// Sets several properties in the disk-image metadata store at once.
    private func setImageProperties(diskName: String, _ properties: [String: String]) {
        Self.imageStoreLock.lock()
        defer { Self.imageStoreLock.unlock() }

        var images = Self.imageStore()
        images[diskName, default: [:]].merge(properties) { _, new in new }
        UserDefaults.standard.set(images, forKey: "images")
    }

    /// Held across every change to the disk-image metadata store. Each change
    /// reads the whole store, edits it and writes it back, and they come from
    /// more than one thread: a save points `resume_image` from the save's
    /// thread, mounts change their slots on the config server's queue, and the
    /// launch replaces stale bookmarks on the boot queue. Without it, two at
    /// once would lose one. Recursive, because the callers that read the slots,
    /// change them and write them back hold it across helpers that take it too.
    private static let imageStoreLock = NSRecursiveLock()

    /// Returns true iff this is a first-boot of the VM.
    func isFirstBoot() -> Bool {
        let image = getResumeImage()
        // FIXME: get rid of instantboot, here; it's just a simple transitionalt hing
        return (image == "") || (image == "instantboot")
    }

    /// Gets the name of the save-state to be used for resuming a VM in "persist
    /// state" mode.
    private func getResumeImage(diskName: String? = nil) -> String {
        let diskName = diskName ?? disk
        return getImageProperty(diskName: diskName, property: "resume_image", defaultValue: "")
    }

    /// The `VmSnapshots.resumeStamp` recorded with the resume image, or empty
    /// if none was.
    private func getResumeStamp(diskName: String? = nil) -> String {
        let diskName = diskName ?? disk
        return getImageProperty(diskName: diskName, property: "resume_stamp", defaultValue: "")
    }

    /// Sets the name of the save-state to be used for resuming a VM in "persist
    /// state" mode, and the stamp of the machine that saved it.
    ///
    /// Both in one write, so a pointer is never seen with another session's
    /// stamp. Anything that isn't a save leaves the stamp empty, which never
    /// matches, and a pointer without one is never resumed.
    ///
    /// The vCPU count goes in the same write. It is not in the stamp, as a
    /// session saved with another count is not stale: it is resumed with the
    /// count it had, and brought to the setting after.
    private func setResumeImage(
        tag: String, stamp: String = "", vcpus: Int? = nil, diskName: String? = nil
    ) {
        let diskName = diskName ?? disk
        setImageProperties(
            diskName: diskName,
            [
                "resume_image": tag, "resume_stamp": stamp,
                "resume_vcpus": vcpus.map(String.init) ?? "",
            ])
    }

    /// Stops pointing the next launch at the saved session.
    ///
    /// For a recovery boot, which throws the session away. The pointer used to
    /// outlive it: a launch that booted afresh left `resume_image` as it was,
    /// and if the app was killed before that fresh session was saved, the next
    /// launch quietly brought back the very session the recovery boot was meant
    /// to discard. The snapshots themselves stay on the disk, as after any
    /// other save, and the next save rotates over them.
    private func forgetSession(because reason: String) {
        let tag = getResumeImage()
        guard !tag.isEmpty, tag != "instantboot" else { return }

        Log.qemu.note("resume: forgetting '\(tag)', as \(reason)")
        setResumeImage(tag: "")
    }

    /// How many vCPUs to launch with: the count the resumed session was saved
    /// with, and otherwise the setting.
    ///
    /// Not a requirement but a head start. Our QEMU brings the machine to the
    /// snapshot's count as the snapshot loads, plugging vCPUs in or taking them
    /// away before any device state is restored, so a snapshot with no record
    /// (one named under Boot From Snapshot, or taken from inside Linux) still
    /// comes back exactly as it was. Launching with the right count just means
    /// there is nothing to change.
    private func launchVcpus(bootImageName: String?) -> Int {
        let setting = Vcpus.foreground

        guard let bootImageName, bootImageName == getResumeImage(),
            let saved = recordedResumeVcpus()
        else {
            return setting
        }

        return saved
    }

    /// The vCPU count saved with the resume image, or nil if there isn't a
    /// usable one.
    private func recordedResumeVcpus() -> Int? {
        guard
            let saved = Int(
                getImageProperty(diskName: disk, property: "resume_vcpus", defaultValue: "")),
            (1...Vcpus.maximum).contains(saved)
        else {
            return nil
        }
        return saved
    }

    /// Ensures we have a connection to our VM over the QEMU management
    /// protocol, returning whether there is one.
    @discardableResult
    private func ensureMonitorConnection() -> Bool {

        // If we already have a connection, we're done! One that has closed is forgotten as soon as
        // that's found, so this one is still open as far as anyone knows.
        if monitorSocket != nil {
            return true
        }

        guard let monitorSocketPath else { return false }

        // Connect to QEMU's HMP monitor.
        guard case .connected(let socket) = SocketConnection.open(monitorSocketPath) else {
            Log.qemu.warn("monitor is not listening at \(monitorSocketPath)")
            return false
        }

        monitorSocket = socket

        // A new connection owes nothing; the banner prompt below is not a debt, it is the greeting,
        // and it is read right here.
        promptsOwed = 0

        // Let the monitor finish introducing itself before anyone talks over it.
        if readUntilPrompt(timeout: Self.monitorBusyDeadline) == nil {
            Log.qemu.warn("the monitor connected but never showed a prompt")
        }

        return true
    }

    /// Linux is restarting without having been asked to, as after `reboot` in
    /// the terminal. Main thread.
    ///
    /// The app learns of it from the guest agent, and treats it much as a
    /// recovery boot: nothing is saved, and nothing is handed vCPUs, until
    /// Linux is up again, and a crash before then is the boot's fault. Unlike
    /// after a recovery boot, the user TTYs keep what they show: Linux chose to
    /// restart, and what they show is the record of why.
    func linuxRestartingItself() {
        UserDefaults.standard.set(true, forKey: "attempting_boot")
        forgetSession(because: "Linux restarted")
        Vcpus.guestRestarting(qemu: self)
        GuestAgent.shared.linuxRestarting()
    }

    /// How `requestRecoveryBoot` went.
    enum RecoveryBoot {
        /// The reset is on its way.
        case started

        /// Something else, such as a save, held the monitor. The session is
        /// still there, and a relaunch resumes it.
        case monitorBusy

        /// The monitor didn't take the reset: QEMU itself is stuck, and a
        /// relaunch boots afresh.
        case stuck
    }

    /// Restarts the VM from scratch, without leaving the app.
    ///
    /// Resets the machine rather than the process. `-loadvm` only applies at
    /// startup, so a reset boots the kernel cold. Restarting QEMU itself isn't
    /// on offer: it runs on a thread inside this process, and telling it to
    /// `quit` would take the app with it.
    ///
    /// Empties the user TTYs too, once QEMU confirms the reset, as what they
    /// show belongs to the session that's gone.
    ///
    /// Returns `.started` once the monitor has taken the reset, `.monitorBusy`
    /// while something else, such as a save, holds the monitor, and `.stuck` if
    /// QEMU is wedged rather than the guest, which nothing in here can fix.
    @discardableResult
    func requestRecoveryBoot() -> RecoveryBoot {
        Log.qemu.note("recovery boot requested; resetting the machine")

        // `attempting_boot` is marked only once the monitor is ours. While a save holds it, the
        // session is still there and the save may yet keep it, and a relaunch must resume that
        // rather than throw it away.
        guard monitorLock.lock(before: Date().addingTimeInterval(Self.monitorBusyDeadline)) else {
            Log.qemu.fail("the monitor is busy, most likely with a save; not resetting")
            return .monitorBusy
        }
        defer { monitorLock.unlock() }

        // Whatever happens next, the resumed session is gone -- so make sure a relaunch doesn't try
        // to pick it up again.
        UserDefaults.standard.set(true, forKey: "attempting_boot")

        // Anything waiting that no command owes, such as a reply that came after its command gave
        // up on it, so that it can't be taken for one of the replies counted below.
        if promptsOwed == 0 {
            drainMonitor()
        }
        let owedBefore = promptsOwed

        guard writeMonitorCommand("system_reset") else {
            Log.qemu.fail("the monitor didn't take system_reset; QEMU itself is stuck")
            return .stuck
        }

        // Then `c`: harmless if the machine is running, and necessary if it isn't. QEMU reads a
        // command one byte per pass of its main loop, and carries out a reset between passes, so it
        // reads the `c` only after the reset. The reply to the `c` therefore means the reset has
        // happened: everything the old session wrote to its consoles is in their sockets, to be
        // thrown away before the terminals are emptied. With no reply in time, the terminals are
        // left alone rather than emptied too soon.
        writeMonitorCommand("c")
        var replies = ""
        let reset = awaitOwedPrompts(within: Self.monitorBusyDeadline, into: &replies)
        if !reset {
            Log.qemu.warn(
                "recovery boot: no reply to the reset in time; not emptying the terminals")
        }

        // The reply to `system_reset` is what came before its prompt, after any owed from before.
        let parts = replies.components(separatedBy: Self.monitorPrompt)
        if reset, parts.count > owedBefore, let failure = Self.monitorError(in: parts[owedBefore]) {
            Log.qemu.fail("the monitor refused system_reset: \(failure)")
            return .stuck
        }

        // Only now that the reset is on its way: a refused one leaves the session running. Linux
        // restarting can't be handed vCPUs until it is up again, and the user TTYs are emptied for
        // it, if the reset is known to have happened.
        forgetSession(because: "Linux was reset")
        let restarting = {
            Vcpus.guestRestarting(qemu: self)
            GuestAgent.shared.linuxRestarting()
            if reset {
                TTYs.shared.resetUserTerminals()
            }
        }
        if Thread.isMainThread {
            restarting()
        } else {
            DispatchQueue.main.async(execute: restarting)
        }
        return .started
    }

    // MARK: Asked for from inside the guest

    /// Why something `tctictl` asked for wasn't done, as a line for the person
    /// who ran it.
    struct GuestRefusal: Error {
        let reason: String

        init(_ reason: String) {
            self.reason = reason
        }
    }

    /// The monitor commands `tctictl monitor` passes on, by name: the read-only
    /// ones. Everything else is for the VM Management TTY, which refuses
    /// nothing. An allowlist, because much of the monitor can break the app's
    /// state or the app itself (`qemu-io` can make it abort), and each QEMU
    /// release adds commands.
    private static let monitorCommandsAllowedToGuest: Set<String> = [
        "info", "help", "?", "x", "xp", "print", "p", "sum",
    ]

    /// How long a snapshot asked for by the guest may take. Longer than a
    /// background save's, since it runs in the foreground.
    private static let guestSnapshotDeadline: TimeInterval = 120

    /// How long other monitor commands from the guest may take.
    private static let guestMonitorDeadline: TimeInterval = 30

    /// `AppDelegate.machineIsAway`, for other threads: whether the machine is
    /// being saved, is parked, or is coming back from a park. The guest's
    /// snapshot and monitor requests check it with `snapshotWorkLock` held,
    /// which the session's save and park also take, so that a request can't
    /// land between them.
    static let machineAway = ManagedAtomic<Bool>(false)

    /// The machine each guest snapshot was taken on, by disk and tag: its vCPU
    /// count and the machine's `resumeStamp`, as "4|<stamp>". A snapshot loads
    /// only into the machine that took it, and QEMU finds a mismatch only after
    /// it has reverted the disk and reset the machine, so a load is refused
    /// unless both match.
    private static var guestSnapshots: [String: String] {
        get {
            UserDefaults.standard.dictionary(forKey: "guest_snapshots") as? [String: String]
                ?? [:]
        }
        set { UserDefaults.standard.set(newValue, forKey: "guest_snapshots") }
    }

    private func guestSnapshotKey(_ tag: String) -> String {
        "\(disk)/\(tag)"
    }

    /// The machine that is running, as `guestSnapshots` records it.
    private static var runningMachineStamp: String {
        VmMemory.bootedArgument.map { VmSnapshots.resumeStamp(memory: $0) } ?? ""
    }

    /// Why the guest's snapshot and monitor requests can't run right now, if
    /// they can't. Call with `snapshotWorkLock` held.
    private static var machineAwayRefusal: GuestRefusal? {
        machineAway.load(ordering: .relaxed)
            ? GuestRefusal("tctiSH is saving your session; try again") : nil
    }

    /// Posted on the main queue when a snapshot the guest asked for fails to
    /// load and Linux is started afresh, with the tag as the object.
    static let guestSnapshotLoadFailed = Notification.Name("io.ara.tctish.guestSnapshotLoadFailed")

    /// Why `tag` can't be used from the guest, if it can't. It must start with
    /// a letter: QEMU's load tries a tag as a snapshot id first, and an id
    /// could be the session's snapshot.
    private static func guestSnapshotRefusal(_ tag: String) -> GuestRefusal? {
        guard tag.range(of: "^[A-Za-z][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
        else {
            return GuestRefusal(
                "a snapshot's name starts with a letter, then up to 63 letters, digits, '.', "
                    + "'_' and '-'")
        }
        guard !ownedSnapshotTags.contains(tag) else {
            return GuestRefusal("'\(tag)' is tctiSH's, for your session; pick another name")
        }
        return nil
    }

    /// Saves a snapshot named `tag` for the guest, which keeps running
    /// afterwards. Off the main thread, while vCPUs aren't changing, which the
    /// caller checks.
    func saveSnapshotForGuest(tag: String) -> Result<String, GuestRefusal> {
        if let refusal = Self.guestSnapshotRefusal(tag) { return .failure(refusal) }

        Self.snapshotWorkLock.lock()
        defer { Self.snapshotWorkLock.unlock() }
        if let refusal = Self.machineAwayRefusal { return .failure(refusal) }

        let started = Date()
        guard let reply = runMonitorCommand("savevm \(tag)", timeout: Self.guestSnapshotDeadline)
        else {
            return .failure(
                GuestRefusal("no answer within \(Int(Self.guestSnapshotDeadline))s"))
        }
        if let failure = Self.monitorError(in: reply) { return .failure(GuestRefusal(failure)) }

        // With no vCPU count, nothing is recorded, so `tctictl` can't load the snapshot.
        let vcpus = vcpuSlots()?.plugged.count
        Self.guestSnapshots[guestSnapshotKey(tag)] =
            vcpus.map { "\($0)|\(Self.runningMachineStamp)" }
        Log.qemu.note(
            String(
                format: "guest snapshot: saved '%@' in %.1fs, %@ vCPUs", tag,
                -started.timeIntervalSinceNow, vcpus.map(String.init) ?? "?"))
        return .success("saved \(tag)")
    }

    /// Loads the snapshot `tag` for the guest and starts it running. Off the
    /// main thread, while vCPUs aren't changing.
    ///
    /// Once the load works, the `tctictl` that asked no longer exists, so the
    /// answer matters only on failure. Only snapshots `saveSnapshotForGuest`
    /// took on this machine, with the vCPUs Linux has now, are loaded: QEMU
    /// reverts the disk and resets the machine before reading the snapshot's
    /// RAM, so a mismatch fails with the machine already gone. If a load fails
    /// anyway, Linux is started afresh, as for a recovery boot, so that the
    /// next background save doesn't keep the broken machine as the session.
    func loadSnapshotForGuest(tag: String, vcpus present: Int?) -> Result<String, GuestRefusal> {
        if let refusal = Self.guestSnapshotRefusal(tag) { return .failure(refusal) }

        let fields = Self.guestSnapshots[guestSnapshotKey(tag)]?.split(
            separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let fields, fields.count == 2, let taken = Int(fields[0]) else {
            return .failure(
                GuestRefusal(
                    "'\(tag)' wasn't saved with 'tctictl snapshot save'; VM Management can try "
                        + "loading it"))
        }
        guard fields[1] == Self.runningMachineStamp else {
            return .failure(
                GuestRefusal(
                    "'\(tag)' was saved by another version of tctiSH, or with other VM Memory, "
                        + "and won't load into this machine"))
        }
        if let present, taken != present {
            return .failure(
                GuestRefusal(
                    "'\(tag)' was taken with \(taken) vCPUs, and Linux has \(present) now"))
        }

        Self.snapshotWorkLock.lock()
        defer { Self.snapshotWorkLock.unlock() }
        if let refusal = Self.machineAwayRefusal { return .failure(refusal) }

        guard let tags = snapshotTagsOnDisk() else {
            return .failure(GuestRefusal("the monitor didn't list the snapshots"))
        }
        guard tags.contains(tag) else {
            return .failure(GuestRefusal("there's no snapshot '\(tag)' on this disk"))
        }

        let reply = runMonitorCommand("loadvm \(tag)", timeout: Self.guestSnapshotDeadline)
        let failure =
            reply.map { Self.monitorError(in: $0) }
            ?? "no answer within \(Int(Self.guestSnapshotDeadline))s"
        if let failure {
            // By now the disk is reverted and the machine reset, and what's left can't run. A
            // reset, as for a recovery boot, starts Linux afresh on the reverted disk, and nothing
            // is saved until it is up.
            Log.qemu.warn("guest snapshot: 'loadvm \(tag)' failed: \(failure); starting afresh")

            // Set here as well, because `requestRecoveryBoot` sets it only once it has the monitor.
            // Whether or not the reset goes through, what's running can't be resumed, so a relaunch
            // must start afresh.
            UserDefaults.standard.set(true, forKey: "attempting_boot")
            let reset = requestRecoveryBoot()
            if reset != .started {
                Log.qemu.warn("guest snapshot: the reset didn't go through (\(reset))")
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.guestSnapshotLoadFailed, object: tag)
            }
            return .failure(GuestRefusal(failure))
        }

        // HMP's loadvm starts the machine again if it was running, which it was.
        if !machineIsRunning() {
            runMonitorCommandCleanly("cont", purpose: "guest snapshot")
        }
        Log.qemu.note("guest snapshot: loaded '\(tag)'")
        DispatchQueue.main.async { Vcpus.machineMayHaveChanged() }
        return .success("loaded \(tag)")
    }

    /// Deletes the snapshot `tag` for the guest.
    func deleteSnapshotForGuest(tag: String) -> Result<String, GuestRefusal> {
        if let refusal = Self.guestSnapshotRefusal(tag) { return .failure(refusal) }

        Self.snapshotWorkLock.lock()
        defer { Self.snapshotWorkLock.unlock() }
        if let refusal = Self.machineAwayRefusal { return .failure(refusal) }

        guard let reply = runMonitorCommand("delvm \(tag)", timeout: Self.guestMonitorDeadline)
        else {
            return .failure(GuestRefusal("no answer within \(Int(Self.guestMonitorDeadline))s"))
        }
        if let failure = Self.monitorError(in: reply) { return .failure(GuestRefusal(failure)) }

        Self.guestSnapshots[guestSnapshotKey(tag)] = nil
        return .success("deleted \(tag)")
    }

    /// Runs a monitor command for `tctictl monitor`, if it's one of
    /// `monitorCommandsAllowedToGuest`, and returns what the monitor printed.
    /// `tctictl snapshot list` comes here too, as `info snapshots`.
    ///
    /// The command goes through the monitor's line editor, so it must be
    /// printable ASCII: a control character or an escape could edit it into
    /// another command, or recall one of the app's from history. A command's
    /// name ends at a `/` as well as a space (`x/16x`). And it mustn't produce
    /// the prompt, which is how the app knows a command has finished: not in
    /// the command, which is echoed, nor through `x/s`, which prints strings
    /// from guest memory.
    func runMonitorCommandForGuest(_ command: String) -> Result<String, GuestRefusal> {
        let line = command.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) })
        else {
            return .failure(GuestRefusal("one command, on one line, in plain ASCII"))
        }
        guard !line.contains(Self.monitorPrompt) else {
            return .failure(GuestRefusal("a command can't contain '\(Self.monitorPrompt)'"))
        }

        let word = String(line.prefix { $0 != " " && $0 != "/" })
        guard Self.monitorCommandsAllowedToGuest.contains(word) else {
            return .failure(
                GuestRefusal(
                    "'\(word)' isn't available from inside Linux, only commands that look "
                        + "(info, x, xp, print, sum, help); VM Management has the rest"))
        }
        if line.range(of: "^xp?[ ]*/[0-9]*[a-z]*s", options: .regularExpression) != nil {
            return .failure(GuestRefusal("x and xp can't print strings (/s) from inside Linux"))
        }

        // Under the lock, like the snapshot requests: not while the machine is being saved or
        // parked.
        Self.snapshotWorkLock.lock()
        defer { Self.snapshotWorkLock.unlock() }
        if let refusal = Self.machineAwayRefusal { return .failure(refusal) }

        guard let reply = runMonitorCommand(line, timeout: Self.guestMonitorDeadline) else {
            return .failure(GuestRefusal("no answer within \(Int(Self.guestMonitorDeadline))s"))
        }
        return .success(Self.forGuest(reply))
    }

    /// A monitor reply as the guest should see it: the lines it printed,
    /// without its echo of the command or its prompt.
    private static func forGuest(_ reply: String) -> String {
        lines(of: reply)
            .filter { !$0.unicodeScalars.contains("\u{1B}") && !$0.hasPrefix(monitorPrompt) }
            .joined(separator: "\n")
    }
}

// MARK: - Debug tools

extension QEMUInterface {

    /// One disk's saved session, as Debug Tools shows it.
    struct SavedSession {
        let disk: String

        /// Whether this is the disk the VM is running from.
        let isRunning: Bool

        /// The snapshot the next launch on this disk would resume, or empty.
        let tag: String

        /// What the machine that saved it recorded; see `resumeStamp`.
        let stamp: String

        /// Whether the next launch would accept it, as far as the stamp goes.
        let stampMatches: Bool
    }

    /// What the next launch requires a saved session's stamp to be.
    static var wantedStamp: String {
        VmSnapshots.resumeStamp(memory: VmMemory.qemuArgument)
    }

    /// Every disk's saved session: each disk image in the data store, and any
    /// disk the metadata store still remembers. The running disk comes first.
    func savedSessions() -> [SavedSession] {
        let running = disk
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let images =
            (try? FileManager.default.contentsOfDirectory(atPath: documents.path))?
            .filter { $0.hasSuffix(".qcow") }
            .map { ($0 as NSString).deletingPathExtension } ?? []
        let remembered = Self.imageStore()

        let others = Set(images).union(remembered.keys).subtracting([running]).sorted()
        let wanted = Self.wantedStamp

        return ([running] + others).map { disk in
            let stamp = getResumeStamp(diskName: disk)
            return SavedSession(
                disk: disk,
                isRunning: disk == running,
                tag: getResumeImage(diskName: disk),
                stamp: stamp,
                stampMatches: stamp == wanted)
        }
    }

    /// The snapshots on the running disk, or nil if the monitor didn't answer.
    ///
    /// Blocks on the monitor, so never call it from the main thread.
    ///
    /// Each tag once, in the order QEMU gave them. The loadable and partial
    /// lists can both name one, and a list with a repeat can't be shown.
    func snapshotsOnRunningDisk() -> [String]? {
        guard let tags = snapshotTagsOnDisk() else { return nil }

        var seen = Set<String>()
        return tags.filter { seen.insert($0).inserted }
    }

    /// Stops a disk's saved session being resumed, so the next launch on it
    /// cold boots. The snapshot itself stays on the disk. Returns why it
    /// couldn't, or nil.
    func forgetSavedSession(disk: String) -> String? {
        // A save rewrites the same store. Without the lock, whichever of the two writes last
        // quietly undoes the other.
        guard Self.snapshotWorkLock.try() else {
            return "a session save is running; try again in a moment"
        }
        defer { Self.snapshotWorkLock.unlock() }

        Log.qemu.note("debug: forgetting the saved session on '\(disk)'")
        setResumeImage(tag: "", diskName: disk)
        return nil
    }

    /// Deletes a snapshot from the running disk, `disk`, and that disk's
    /// pointer at it if it has one. Returns why it couldn't, or nil.
    ///
    /// Blocks on the monitor, so never call it from the main thread.
    func deleteSnapshot(_ tag: String, onRunningDisk disk: String) -> String? {
        // Against a save as much as the stale-snapshot discard is: both write the tags this
        // deletes, and the save points the disk at one.
        guard Self.snapshotWorkLock.try() else {
            return "a session save is running; try again in a moment"
        }
        defer { Self.snapshotWorkLock.unlock() }

        guard let reply = runMonitorCommand("delvm \(tag)", timeout: Self.monitorReplyDeadline)
        else {
            return "the monitor didn't answer"
        }

        if let failure = Self.monitorError(in: reply) {
            return failure
        }

        // Checked rather than trusted: `delvm` is silent about a tag it didn't find, so no error is
        // not the same as deleted.
        guard let remaining = snapshotTagsOnDisk() else {
            return "the monitor didn't answer when asked whether it was gone"
        }

        guard !remaining.contains(tag) else {
            Log.qemu.warn(
                "debug: 'delvm \(tag)' left it on the disk; monitor said: " + Self.forLogging(reply)
            )
            return "QEMU reported no error, but '\(tag)' is still on the disk"
        }

        Log.qemu.note("debug: deleted snapshot '\(tag)'")

        if getResumeImage(diskName: disk) == tag {
            setResumeImage(tag: "", diskName: disk)
        }

        return nil
    }
}

// MARK: - Compacting the disk

extension QEMUInterface {

    /// How a compaction ended.
    enum Compaction {
        /// The machine runs on the compacted disk. Lengths are the file's, in
        /// bytes: `before`, with `beforeOnDisk` the space it took; `after` as
        /// compacted; and `withSave` once the session was saved onto it, which
        /// adds the guest's memory. `withSave` is nil if that save failed, in
        /// which case the next launch boots afresh.
        case compacted(before: Int64, beforeOnDisk: Int64, after: Int64, withSave: Int64?)

        /// Nothing changed, because of `reason`.
        case notDone(String)
    }

    /// Copies the running disk into a fresh qcow2 and moves the machine onto
    /// it, without stopping.
    ///
    /// The file only ever grows, as a qcow2 is as long as the furthest cluster
    /// it has used. QEMU's mirror copies only the clusters in use, and the
    /// guest discards what's frees, so the copy is only as long as what Linux
    /// holds. The guest runs throughout: the mirror tracks what it writes, and
    /// `block_job_complete` switches the drive over once the copy has caught
    /// up.
    ///
    /// Saved sessions don't come across as they are only in the old file, which
    /// the copy replaces, so the session is saved again onto the new one
    /// immediately.
    ///
    /// Blocks for as long as the copy takes, so never call it on the main
    /// thread. `progress` is called from this thread too.
    func compactDisk(progress: (Double) -> Void) -> Compaction {
        // Against a save above all, which writes into the very file this replaces.
        guard Self.snapshotWorkLock.try() else {
            return .notDone("a session save is running; try again in a moment")
        }
        defer { Self.snapshotWorkLock.unlock() }

        let current = getDatastoreURL(disk, fileExtension: "qcow", create: false)
        let target = Self.compactionTarget(for: current)

        guard let before = Self.fileLength(current) else {
            return .notDone("the disk image couldn't be read")
        }

        // What the copy can need at most: everything the old file holds. Its saves don't come
        // across, so this overstates it, which is the right way to be wrong here.
        let allocated = Self.allocatedSize(current) ?? before
        let needed = allocated + Self.compactionHeadroom
        if let available = Self.availableSpace(near: current), available < needed {
            return .notDone(
                "compacting needs up to \(Self.bytes(needed)) free, and there is "
                    + "\(Self.bytes(available))")
        }

        Log.fs.note(
            "compact: copying \(current.lastPathComponent), \(Self.bytes(before)) long, "
                + "\(Self.bytes(allocated)) allocated")
        let started = Date()

        // Undoes everything QEMU might have started, and removes the copy. Only for before the
        // switch: afterwards the copy is the disk.
        func abandon(_ reason: String) -> Compaction {
            runMonitorCommand("block_job_cancel -f drive1", timeout: Self.monitorReplyDeadline)
            waitForNoBlockJobs(within: Self.compactionSettleDeadline)
            try? FileManager.default.removeItem(at: target)
            Log.fs.warn("compact: abandoned: \(reason)")
            return .notDone(reason)
        }

        let quotedTarget = Self.hmpQuoted(target.path)
        guard
            let reply = runMonitorCommand(
                "drive_mirror -f drive1 \(quotedTarget) qcow2",
                timeout: Self.monitorReplyDeadline)
        else {
            return abandon("the monitor didn't answer")
        }
        if let failure = Self.monitorError(in: reply) {
            return abandon("QEMU wouldn't start the copy: \(failure)")
        }

        // Until it has caught up, then until QEMU agrees to switch. `block_job_complete` is refused
        // until the job is ready: the counts keep moving for as long as the guest writes.
        var caughtUp = false
        var unanswered = 0
        while true {
            guard
                let jobs = runMonitorCommand(
                    "info block-jobs", timeout: Self.monitorReplyDeadline)
            else {
                unanswered += 1
                if unanswered >= Self.compactionUnansweredLimit {
                    return abandon("the monitor stopped answering")
                }
                continue
            }
            unanswered = 0

            guard let (done, total) = Self.mirrorProgress(in: jobs) else {
                return abandon("the copy stopped with an error")
            }

            if total > 0 {
                progress(min(1, Double(done) / Double(total)))
            }
            caughtUp = caughtUp || (total > 0 && done == total)

            if caughtUp,
                let reply = runMonitorCommand(
                    "block_job_complete drive1", timeout: Self.monitorReplyDeadline),
                Self.monitorError(in: reply) == nil
            {
                break
            }

            Thread.sleep(forTimeInterval: Self.compactionPollInterval)
        }

        // Nothing may touch the copy while the job could still switch onto it: deleting it then
        // would leave the drive writing into a file that is gone.
        if !waitForNoBlockJobs(within: Self.compactionSettleDeadline) {
            runMonitorCommand("block_job_cancel -f drive1", timeout: Self.monitorReplyDeadline)
            guard waitForNoBlockJobs(within: Self.compactionSettleDeadline) else {
                Log.fs.fail("compact: the job won't finish or cancel; leaving both files")
                return .notDone("QEMU didn't finish switching to the copy")
            }
        }

        // Checked rather than assumed. If the drive is still on the old file the switch failed, and
        // the copy goes. If the answer can't be had at all, neither file can safely be touched:
        // both are left, and the next launch, which runs from the old one, removes the copy.
        guard let block = runMonitorCommand("info block drive1", timeout: Self.monitorReplyDeadline)
        else {
            Log.fs.fail("compact: couldn't ask QEMU which file the drive is on; leaving both")
            return .notDone("QEMU didn't say whether it switched to the copy")
        }
        guard block.contains(target.lastPathComponent) else {
            try? FileManager.default.removeItem(at: target)
            Log.fs.warn("compact: QEMU didn't switch; monitor said: " + Self.forLogging(block))
            return .notDone("QEMU didn't switch to the copy")
        }

        // The machine is on the copy now, under the copy's name. Moved over the old one at once,
        // since the next launch opens the disk by its usual name. Until this lands, a crash leaves
        // the old file and its saves, which resume consistently, as after any crash.
        //
        // rename() to perform it in one atomic step, and QEMU's open descriptor follows the file to
        // its new name. The old file is unlinked here, and its space comes back once QEMU, which
        // let go of it at the switch, has closed it.
        guard rename(target.path, current.path) == 0 else {
            let reason = String(cString: strerror(errno))
            Log.fs.fail("compact: couldn't move the copy over the disk: \(reason)")
            return .notDone(
                "the copy couldn't replace the disk (\(reason)); changes from now on will be "
                    + "lost when the app closes")
        }

        let after = Self.fileLength(current) ?? 0

        // The saves went with the old file.
        setResumeImage(tag: "")
        let saved = saveSession(as: getNextInstantResumeTag())
        let withSave = saved ? Self.fileLength(current) : nil

        Log.fs.note(
            String(
                format: "compact: %@ now %@ long, was %@; took %.1fs; %@",
                current.lastPathComponent, Self.bytes(after), Self.bytes(before),
                -started.timeIntervalSinceNow,
                withSave.map { "session saved, \(Self.bytes($0)) with it" }
                    ?? "session not saved, so the next launch boots afresh"))

        return .compacted(
            before: before, beforeOnDisk: allocated, after: after, withSave: withSave)
    }

    /// The running disk image's length, which is what the Files app shows and
    /// what compacting shortens, and the space it takes on disk, which is what
    /// iOS counts against the app.
    var diskSizes: (length: Int64, onDisk: Int64)? {
        let url = getDatastoreURL(disk, fileExtension: "qcow", create: false)
        guard let length = Self.fileLength(url) else { return nil }
        return (length, Self.allocatedSize(url) ?? length)
    }

    /// Removes copies a compaction left behind when the app went before it
    /// finished. Call before QEMU opens `disk`.
    ///
    /// Any such copy predates the switch: the switch is followed at once by the
    /// move over the disk, which takes the copy's name away. So the disk is the
    /// one with the data, and the copy is only space.
    static func removeAbandonedCompactions(of disk: URL) {
        let folder = disk.deletingLastPathComponent()
        let prefix = disk.lastPathComponent + compactionSuffix

        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            Log.fs.note("compact: removing \(name), left by a compaction that didn't finish")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Waits for QEMU to have no block job running, for up to `deadline`.
    /// Returns whether it got there.
    @discardableResult
    private func waitForNoBlockJobs(within deadline: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if let jobs = runMonitorCommand("info block-jobs", timeout: Self.monitorReplyDeadline),
                jobs.contains("No active jobs")
            {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Log.fs.warn("compact: a block job was still running after \(Int(deadline))s")
        return false
    }

    /// The bytes done and to do of the drive's mirror, or nil if there's no
    /// job. "Type mirror, device drive1: Completed 123 of 456 bytes, ...".
    private static func mirrorProgress(in reply: String) -> (Int64, Int64)? {
        for line in lines(of: reply) where line.contains("device drive1:") {
            let words = line.split(separator: " ")
            guard let at = words.firstIndex(of: "Completed"), words.count > at + 3,
                let done = Int64(words[at + 1]), let total = Int64(words[at + 3])
            else { continue }
            return (done, total)
        }
        return nil
    }

    /// A unique name beside `disk` for the copy. Unique, because QEMU keeps the
    /// name a file was opened with, so after one compaction the drive's name in
    /// QEMU is the copy's, and a second must not reuse it.
    private static func compactionTarget(for disk: URL) -> URL {
        let tag = UUID().uuidString.prefix(8).lowercased()
        return disk.deletingLastPathComponent()
            .appendingPathComponent(disk.lastPathComponent + compactionSuffix + tag)
    }

    /// Not ".qcow": the copy is not a separate disk, and the Saved Sessions
    /// list takes every ".qcow" for one.
    private static let compactionSuffix = ".compacting-"

    /// Free space kept in hand beyond the copy itself.
    private static let compactionHeadroom: Int64 = 256 << 20

    /// How often to look at the copy's progress.
    private static let compactionPollInterval: TimeInterval = 0.25

    /// How long the job may take to go away once completed or cancelled.
    private static let compactionSettleDeadline: TimeInterval = 30

    /// Unanswered progress checks in a row before giving up on the copy.
    private static let compactionUnansweredLimit = 5

    /// An HMP string argument: double-quoted, with the escapes its parser
    /// understands, so a disk name with a space in it survives.
    private static func hmpQuoted(_ text: String) -> String {
        let escaped =
            text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Read with stat() each time. A URL's resource values are cached on the
    /// URL, and the disk's URL outlives the file it named: after the copy is
    /// moved over it, they would still describe the old file.
    private static func fileLength(_ url: URL) -> Int64? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Int64(info.st_size)
    }

    /// The space the file takes, holes excluded. st_blocks is in 512-byte units
    /// whatever the file system's block size.
    private static func allocatedSize(_ url: URL) -> Int64? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Int64(info.st_blocks) * 512
    }

    private static func availableSpace(near url: URL) -> Int64? {
        let folder = url.deletingLastPathComponent()
        return
            (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage).flatMap { $0 }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
