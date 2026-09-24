//
//  QEMULauncher
//  Swift interfacing code for launching our internal QEMU.
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright ©2022 Kate Temkin. All rights reserved.
//

import Socket
import Foundation

/// Structure that stores the metadata associated with a given mount.
struct DiskMountInfo: Codable {

    /// The bookmark data assosciated with the disk mount.
    var bookmark: Data

    /// The tag used for configuring the fsdev backing file provider.
    var fsdev_tag: String

    /// The tag used for mounting the device into the VM.
    var mount_tag: String
}

/// Provides an interface for running / controlling a QEMU VM.
public class QEMUInterface {

    /// The hostfwd pattern used to make SSH connections available to the
    /// application.
    private static let sshHostForward: String = "tcp:127.0.0.1:10022-:22"

    /// The port on which we connect using the QEMU monitor.
    private static let monitorPort: Int32 = 10044

    /// Our QEMU human-readable protocol socket.
    ///
    /// Private, and touched only with `monitorLock` held: there is one of these
    /// and more than one thread that wants it.
    private var monitorSocket: Socket?
    private var monitorSocketPath: String?

    /// Start our background QEMU thread.
    func startQemuThread(forceRecoveryBoot: Bool = false) {

        // Clear any state left over from previous runs.
        clearLastCWDFile()

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

        // ... find where our QEMU binary is actually located ...
        let qemuImage = getAppropriateQemuFramework().path

        // ... figure out the folder we'll be sharing into our environment ...
        let sharedFolder = getSharedFolder().path

        // ... figure out how much memory to give the VM, and how much code cache ...
        let memoryValue = VmMemory.qemuArgument
        let tbSize = CodeCache.tbSizeArgument

        // ... get a filename for our unix domain monitor-connection socket ...
        monitorSocketPath = getDatastoreURL("monitor", fileExtension: "socket").path

        // Say what we're about to run. A hung VM looks identical whichever build and boot image
        // produced it, and those are exactly the two things that determine whether it *can* boot --
        // a snapshot taken under one QEMU build is not necessarily loadable by the other.
        Log.qemu.note(
            "\(getAppropriateQemuFramework().lastPathComponent), "
                + "accel tcg\(AppDelegate.usingJitHacks ? ",split-wx=on" : ""),tb-size=\(tbSize), "
                + "bless \(AppDelegate.blessJitRegions)")
        Log.qemu.note(
            "\(bootImageName.map { "resuming from '\($0)'" } ?? "cold boot"), "
                + "memory \(memoryValue), code cache \(CodeCache.summary)")

        // ... and start up the QEMU kernel, which will start paused.
        run_background_qemu(
            qemuImage, kernelPath, initrdPath, bundlePrefix, diskPath, sharedFolder, bootImageName,
            memoryValue, monitorSocketPath, AppDelegate.usingJitHacks, AppDelegate.blessJitRegions,
            UInt32(tbSize), UInt32(CodeCache.initialSize));

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
    static var lastSaveFailed: Bool {
        get { UserDefaults.standard.bool(forKey: "last_save_failed") }
        set { UserDefaults.standard.set(newValue, forKey: "last_save_failed") }
    }

    /// Snapshots the session, and points the next launch at it if it worked.
    ///
    /// Returns whether the session was saved.
    ///
    /// Call off the main thread, and only once the shell has connected: a
    /// snapshot of a machine that has not finished booting is not worth
    /// resuming, and the check is a view's, so the caller makes it.
    @discardableResult
    func performBackgroundSave() -> Bool {
        // See snapshotWorkLock: this whole sequence has to be atomic against a stale-snapshot
        // discard, which deletes the very tags this rotates between.
        Self.snapshotWorkLock.lock()
        defer { Self.snapshotWorkLock.unlock() }

        let tag = getNextInstantResumeTag()
        let started = Date()

        guard let reply = runMonitorCommand("savevm \(tag)", timeout: Self.saveDeadline) else {
            reportSaveFailure(
                "'savevm \(tag)' did not finish within \(Int(Self.saveDeadline))s")
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

        // Only having been told the snapshot is really there. Stamped with the machine that is
        // running, which is what the snapshot holds; see `resumeStamp`.
        let stamp = VmMemory.bootedArgument.map { VmSnapshots.resumeStamp(memory: $0) } ?? ""
        setResumeImage(tag: tag, stamp: stamp)
        Self.lastSaveFailed = false

        // Including anything `reportSaveRanOutOfTime` left queued. The assertion running out did
        // not stop the work, and the work went on to succeed.
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

        LocalAlert.post(
            title: "Session not saved",
            body: Self.saveFailureBody,
            id: Self.saveFailureAlertId)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.saveDidFail, object: nil)
        }
    }

    /// Records that the save has run out of time, and says so unless it
    /// finishes after all.
    ///
    /// Not `reportSaveFailure`, because an assertion expiring is a different
    /// fact from a save that failed. iOS is saying "hand this back now"; it is
    /// not stopping the work, which carries on under its own deadlines and
    /// quite often succeeds.
    ///
    /// The delay is the save's own deadline, so it fires at the moment the save
    /// has definitively run out of road rather than at some guess.
    func reportSaveRanOutOfTime() {
        Log.qemu.warn("session save: ran out of time in the background")
        Self.lastSaveFailed = true

        LocalAlert.post(
            title: "Session not saved",
            body: Self.saveFailureBody,
            id: Self.saveFailureAlertId,
            after: Self.saveDeadline)
    }

    /// What resuming will do, rather than by what is "lost", because which of
    /// those is true depends on what happens next.
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

    /// How long a snapshot may take before we stop waiting for it.
    ///
    /// Sized against what iOS gives a background task rather than against any
    /// measurement of `savevm`, which scales with how much RAM the guest was
    /// given and can be several gigabytes of it.
    private static let saveDeadline: TimeInterval = 20

    /// How long to wait for a monitor command that only has to answer.
    private static let monitorReplyDeadline: TimeInterval = 5

    /// The HMP prompt, and so the only reliable "that command has finished".
    private static let monitorPrompt = "(qemu)"

    /// Serialises everything that talks to the monitor.
    ///
    /// One socket, one command at a time, one reader. `savevm` holds it for as
    /// long as the snapshot takes. The collision this prevents is not
    /// hypothetical: locking the device is both what backgrounds the app, which
    /// starts a save on a background thread, and what fires
    /// `applicationProtectedDataWillBecomeUnavailable`, which sends
    /// `hostfwd_remove` from the main one. Interleaved, the second command's
    /// prompt is read as the first command finishing.
    private let monitorLock = NSLock()

    /// Where queued commands run, in the order they were asked for.
    ///
    /// Serial, so `hostfwd_remove` cannot overtake `halt`, and off the main
    /// thread, because the lock above may be held by a snapshot for twenty
    /// seconds and nothing on the main thread may wait that long.
    private let monitorQueue = DispatchQueue(label: "io.ara.tctish.monitor")

    /// How long to wait for the monitor when something else is using it.
    private static let monitorBusyDeadline: TimeInterval = 2

    /// How many replies the monitor still owes us.
    ///
    /// Every HMP command ends by printing a fresh prompt, so a command written
    /// without its reply being read leaves one sitting in the socket, and the
    /// next command to read finds it there and stops on it, returning before
    /// its own output has arrived. Draining first only helps if the stray
    /// prompt has already landed, which is a race rather than a guarantee.
    ///
    /// Counting them means a reader can settle the debt by waiting rather than
    /// by hoping. Written and read only with `monitorLock` held.
    private var promptsOwed = 0

    /// Reads off the replies to commands nobody waited for.
    ///
    /// Call with `monitorLock` held, before reading for a command of your own.
    private func settleOutstandingPrompts() {
        while promptsOwed > 0 {
            guard readUntilPrompt(timeout: Self.monitorReplyDeadline) != nil else {
                Log.qemu.warn("the monitor owes \(promptsOwed) replies and isn't giving them")

                // The state of the connection is no longer known, so neither is the count. Whatever
                // arrives later is the next drain's problem rather than a debt that can never be
                // settled. Left standing, it would make every future command wait out this deadline
                // before doing anything.
                promptsOwed = 0
                return
            }

            promptsOwed -= 1
        }
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
    /// Blocks for up to `timeout`, so never call it from the main thread.
    @discardableResult
    private func runMonitorCommand(_ command: String, timeout: TimeInterval) -> String? {
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

        guard let response = readUntilPrompt(timeout: timeout) else {
            Log.qemu.warn("monitor never came back to its prompt after '\(command)'")
            promptsOwed = 0
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
        guard (try? monitorSocket.write(from: terminated.data(using: .utf8)!)) != nil else {
            return false
        }

        promptsOwed += 1
        return true
    }

    /// Waits up to `milliseconds` for the monitor to have something to say.
    ///
    /// `Socket.wait` rather than the socket's own `isReadableOrWritable`, which
    /// looks like the obvious call but isn't: it selects on the write set as
    /// well as the read set, and a connected socket with an empty send buffer
    /// is always writable.
    ///
    /// `Socket.wait` is the same `select` with the write set left out.
    private func monitorHasOutput(within milliseconds: UInt) -> Bool {
        guard let monitorSocket else { return false }

        let ready = try? Socket.wait(for: [monitorSocket], timeout: milliseconds)
        return ready?.isEmpty == false
    }

    /// Reads until the monitor's prompt comes round. Call with the lock held.
    private func readUntilPrompt(timeout: TimeInterval) -> String? {
        guard let monitorSocket else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        var response = ""

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }

            // Milliseconds, and sliced so that a long `savevm` still notices the deadline rather
            // than sitting in one enormous select.
            let slice = UInt(max(min(remaining, 1) * 1000, 1))

            guard monitorHasOutput(within: slice) else { continue }

            // Readable with nothing to give means the far end has gone.
            guard let chunk = try? monitorSocket.readString(), !chunk.isEmpty else {
                Log.qemu.warn("the monitor connection closed")
                return nil
            }

            response += chunk

            if response.contains(Self.monitorPrompt) {
                return response
            }
        }
    }

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
        guard let monitorSocket else { return }

        while monitorHasOutput(within: 0),
            let leftover = try? monitorSocket.readString(),
            !leftover.isEmpty
        {}
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

        for line in Self.lines(of: response) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if text.isEmpty || text.hasPrefix("List of") || text.hasPrefix("ID ") {
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
    private static let ownedSnapshotTags = ["instant_resume_a", "instant_resume_b", "instantboot"]

    /// Clears up snapshots that describe a machine this build no longer makes.
    ///
    /// Not only a QEMU upgrade: the epoch also covers the machine's shape and
    /// the bundled guest kernel, so a new kernel or a changed device list lands
    /// here too. See `VmSnapshots`.
    ///
    /// Call off the main thread, once the shell is up: it talks to the monitor,
    /// and `savevm`-adjacent commands want a machine that has finished booting.
    func discardPreUpgradeSnapshots() {
        guard VmSnapshots.changedSinceLastBoot else { return }

        // Once per process. `connected` goes back to false on a dropped session and true again on
        // the reconnect, so the notification that brings us here is not as once-only as its comment
        // suggests.
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
            diskName: getDiskName(), property: "resume_image", defaultValue: "b")

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

    /// Terminates the SSH channel used for console comms.
    func stopHostChannels() {
        sendMonitorCommand("hostfwd_remove \(QEMUInterface.sshHostForward)")
    }

    /// Terminates the SSH channel used for console comms.
    func startHostChannels() {
        sendMonitorCommand("hostfwd_add \(QEMUInterface.sshHostForward)")
    }

    /// Sets up the permissions for using a bookmarked folder. Used to restore
    /// access to an iOS folder.
    private func setupMountPermissions(bookmarkData: Data) -> URL? {
        var isStale = false;

        // Rehydrate our data back into a bookmark...
        let hostPath = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
        guard (hostPath != nil) && !isStale else {
            return nil
        }

        // ... revive its security context ...
        _ = hostPath?.startAccessingSecurityScopedResource()

        return hostPath
    }

    /// Sets up a given host URL for mounting.
    func mount(
        bookmarkData: Data, interfaceId: String? = nil, predefinedTag: String? = nil,
        persistent: Bool = true
    ) -> String? {
        let tag = predefinedTag ?? generateMountTag(length: 6)
        let id = interfaceId ?? generateMountTag(length: 6)

        let hostPath = setupMountPermissions(bookmarkData: bookmarkData)

        // ... and, finally, mount the target URL.
        if persistent {
            makeMountPersistent(bookmarkData: bookmarkData, interfaceId: id, tag: tag)
        }
        return mount(hostPath: hostPath!, interfaceId: id, predefinedTag: tag)
    }

    /// Saves mount data into our "VM" configuration, so we can automatically
    /// remount it on startup.
    private func makeMountPersistent(bookmarkData: Data, interfaceId: String, tag: String) {

        // Get an encapsulation of our mount data...
        let mountInfo = DiskMountInfo(
            bookmark: bookmarkData, fsdev_tag: interfaceId, mount_tag: tag)
        let serializedData = try! JSONEncoder().encode(mountInfo)
        let serializedString = String(data: serializedData, encoding: .utf8)!

        // ... and associate it with this image.
        let slot = getNextMountSlotName()
        setImageProperty(diskName: getDiskName(), property: slot, value: serializedString)
    }

    /// Returns the next ImageProperty name appropriate for storing a
    private func getNextMountSlotName() -> String {
        let existingSlots = getPersistentMounts().count
        return "disk_mount_\(existingSlots)"
    }

    /// Returns all known disk-mount data, so persistent disks can be remounted.
    private func getPersistentMounts() -> [DiskMountInfo] {
        var slot = 0
        var mounts: [DiskMountInfo] = []

        while true {
            let mount_info = getMountInfo(slotName: "disk_mount_\(slot)")
            if let mount_info = mount_info {
                mounts.append(mount_info)
            } else {
                return mounts
            }

            slot += 1
        }
    }

    /// Returns any mount information associated with a given disk mount slot;
    /// or nil if the slot wasn't present.
    private func getMountInfo(slotName: String, disk: String? = nil) -> DiskMountInfo? {

        // Fetch any data stored in the current mount slot.
        let diskName = disk ?? getDiskName()
        let serializedString = getImageProperty(
            diskName: diskName, property: slotName, defaultValue: "")
        let serializedData = Data(serializedString.utf8)

        // If there wasn't any, early abort.
        guard serializedString != "" else {
            return nil
        }

        // Finally, parse the data back into mount-info.
        return try? JSONDecoder().decode(DiskMountInfo.self, from: serializedData)
    }

    /// Re-creates a mount point on image startup.
    private func recreatePersistentMount(mount_info: DiskMountInfo) {
        _ = self.setupMountPermissions(bookmarkData: mount_info.bookmark)
    }

    /// Re-creates all mounts from the persistent mount pool.
    private func recreatePersistentMounts() {
        for mount in self.getPersistentMounts() {
            self.recreatePersistentMount(mount_info: mount)
        }
    }

    /// Sets up a given host URL for mounting.
    func mount(hostPath: URL, interfaceId: String? = nil, predefinedTag: String? = nil) -> String {
        return mount(
            hostPath: hostPath.path, interfaceId: interfaceId, predefinedTag: predefinedTag)
    }

    /// Sets up a given host path for mounting.
    func mount(hostPath: String, interfaceId: String? = nil, predefinedTag: String? = nil) -> String
    {
        let tag = predefinedTag ?? generateMountTag(length: 6)

        // Use our tag to get a unique symlink path...
        var symlinkDestination = getSharedFolder()
        symlinkDestination.appendPathComponent(tag, isDirectory: true)

        // ... and then create a symlink to the target.
        if FileManager.default.fileExists(atPath: symlinkDestination.path) {
            try? FileManager.default.removeItem(at: symlinkDestination)
        }
        try? FileManager.default.createSymbolicLink(
            atPath: symlinkDestination.path, withDestinationPath: hostPath)

        return tag
    }

    /// Generates a random tag suitable for use in mounting.
    private func generateMountTag(length: Int = 12) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return "m" + String((0..<length).map { _ in letters.randomElement()! })
    }

    /// Fetches the path to the QEMU framework appropriate for this environment.
    /// Will return a JIT-capable image if JIT is supported; or a TCTI image
    /// otherwise.
    private func getAppropriateQemuFramework() -> URL {
        var frameworkURL = Bundle.main.bundleURL
        frameworkURL.appendPathComponent("Frameworks", isDirectory: true)

        // Select our QEMU binary based on whether or not we're allowed to JIT.
        var qemuName = "qemu-x86_64-softmmu"
        if (AppDelegate.usingJitHacks) {
            qemuName += "_jit"
            AppDelegate.usingJitHacks = true
        }

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
            let wanted = VmSnapshots.resumeStamp(memory: VmMemory.qemuArgument)
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
    private func getDiskName() -> String {
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
        let diskName = getDiskName()

        // Figure out where our persistent store would be located.
        let targetURL = getDatastoreURL(diskName, fileExtension: "qcow")

        // If it doesn't exist, create a new copy based on our empty disk.
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            let emptyDiskURL = Bundle.main.url(forResource: "empty", withExtension: "qcow")
            try! FileManager.default.copyItem(at: emptyDiskURL!, to: targetURL)

            // Reset the startup to base instant-boot, since we now have a new disk.
            setResumeImage(tag: "instantboot")
        }

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

    /// Returns the path of a shared file that can be used to pass our last-cwd
    /// to the guest. Contents of the file are managed by our console frontend.
    static func getLastCWDFile() -> URL {
        var cwdFile = QEMUInterface.getSharedFolder()
        cwdFile.appendPathComponent("last_cwd.dat")

        return cwdFile
    }

    /// Removes any last-CWD file present, which is used to store the current
    /// CWD.
    func clearLastCWDFile() {
        let cwdFile = QEMUInterface.getLastCWDFile()

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

    /// Returns a property from the disk-image metadata store.
    private func getImageProperty(diskName: String, property: String, defaultValue: String)
        -> String
    {
        let imageStore =
            UserDefaults.standard.dictionary(forKey: "images") as? [String: [String: String]]
        let images = imageStore ?? [:]
        let image = images[diskName] ?? [:]
        return image[property] ?? defaultValue
    }

    /// Sets a property from the disk-image metadata store.
    private func setImageProperty(diskName: String, property: String, value: String) {
        setImageProperties(diskName: diskName, [property: value])
    }

    /// Sets several properties in the disk-image metadata store at once.
    private func setImageProperties(diskName: String, _ properties: [String: String]) {

        // Get the current image-store...
        let imageStore =
            UserDefaults.standard.dictionary(forKey: "images") as? [String: [String: String]]
        var images = imageStore ?? [:]

        // ... update the relevant property values ...
        images[diskName, default: [:]].merge(properties) { _, new in new }

        // ... and save it back to our configuration.
        UserDefaults.standard.set(images, forKey: "images")
    }

    /// Returns true iff this is a first-boot of the VM.
    func isFirstBoot() -> Bool {
        let image = getResumeImage()
        // FIXME: get rid of instantboot, here; it's just a simple transitionalt hing
        return (image == "") || (image == "instantboot")
    }

    /// Gets the name of the save-state to be used for resuming a VM in "persist
    /// state" mode.
    private func getResumeImage(diskName: String? = nil) -> String {
        let diskName = diskName ?? getDiskName()
        return getImageProperty(diskName: diskName, property: "resume_image", defaultValue: "")
    }

    /// The `VmSnapshots.resumeStamp` recorded with the resume image, or empty
    /// if none was.
    private func getResumeStamp(diskName: String? = nil) -> String {
        let diskName = diskName ?? getDiskName()
        return getImageProperty(diskName: diskName, property: "resume_stamp", defaultValue: "")
    }

    /// Sets the name of the save-state to be used for resuming a VM in "persist
    /// state" mode, and the stamp of the machine that saved it.
    ///
    /// Both in one write, so a pointer is never seen with another session's
    /// stamp. Anything that isn't a save leaves the stamp empty, which never
    /// matches, and a pointer without one is never resumed.
    private func setResumeImage(tag: String, stamp: String = "", diskName: String? = nil) {
        let diskName = diskName ?? getDiskName()
        setImageProperties(diskName: diskName, ["resume_image": tag, "resume_stamp": stamp])
    }

    /// Ensures we have a connection to our VM over the QEMU management
    /// protocol, returning whether there is one.
    @discardableResult
    private func ensureMonitorConnection() -> Bool {

        // If we already have a connection, we're done!
        if let monitorSocket = monitorSocket {
            if monitorSocket.isConnected {
                return true
            }
        }

        guard let monitorSocketPath else { return false }

        // Create a connection to QEMU via QMP.
        guard let socket = try? Socket.create(family: .unix, type: .stream, proto: .unix) else {
            Log.qemu.fail("could not create a monitor socket")
            return false
        }

        do {
            try socket.connect(to: monitorSocketPath)
        } catch {
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

    /// Restarts the VM from scratch, without leaving the app.
    ///
    /// Resets the machine rather than the process. `-loadvm` only applies at
    /// startup, so a reset boots the kernel cold. Restarting QEMU itself isn't
    /// on offer: it runs on a thread inside this process, and telling it to
    /// `quit` would take the app with it.
    ///
    /// Returns whether the monitor took the command. It won't if QEMU is wedged
    /// rather than the guest, and there is nothing to be done about that from
    /// in here.
    @discardableResult
    func requestRecoveryBoot() -> Bool {
        Log.qemu.note("recovery boot requested; resetting the machine")

        // Whatever happens next, the resumed session is gone -- so make sure a relaunch doesn't try
        // to pick it up again.
        UserDefaults.standard.set(true, forKey: "attempting_boot")

        guard monitorLock.lock(before: Date().addingTimeInterval(Self.monitorBusyDeadline)) else {
            Log.qemu.fail("the monitor is busy saving the session; not resetting")
            return false
        }
        defer { monitorLock.unlock() }

        guard writeMonitorCommand("system_reset") else {
            Log.qemu.fail("the monitor didn't take system_reset; QEMU itself is stuck")
            return false
        }

        // Harmless if it's already running, and necessary if it isn't.
        writeMonitorCommand("c")
        return true
    }
}
