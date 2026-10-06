//
//  Vcpus.swift
//  How many vCPUs Linux has, and in the background where they run, changed while it runs.
//
//  Copyright © 2026 Ara Adkins.
//

import Atomics
import UIKit

/// Which of the device's cores the vCPUs may run on in the background.
///
/// Not a choice of particular cores: iOS supports no affinity, and the one
/// placement it lets an app insist on is that background-QoS threads stay on
/// the efficiency cores.
enum CoreClass: String, CaseIterable {

    /// Wherever iOS puts them.
    case any = "any"

    /// The efficiency cores only. Much slower, and easier on the battery.
    case efficiency = "efficiency"

    var title: String {
        switch self {
        case .any: "Any Core"
        case .efficiency: "Efficiency Cores Only"
        }
    }

    /// What the vCPU threads are put in. Unspecified for `any`, which QEMU
    /// takes as "the class each thread started in", so that it leaves the vCPUs
    /// exactly as they would run had nothing been chosen.
    var qos: qos_class_t {
        switch self {
        case .any: QOS_CLASS_UNSPECIFIED
        case .efficiency: QOS_CLASS_BACKGROUND
        }
    }
}

/// How many of the foreground's vCPUs Linux keeps in the background.
enum BackgroundShare: String, CaseIterable {
    case all = "all"
    case half = "half"
    case quarter = "quarter"
    case one = "one"

    var title: String {
        switch self {
        case .all: "Same as Foreground"
        case .half: "Half"
        case .quarter: "A Quarter"
        case .one: "One"
        }
    }

    /// The count this leaves of `foreground`: rounded up, so that a share is
    /// never less than it says, and never none.
    func count(of foreground: Int) -> Int {
        switch self {
        case .all: foreground
        case .half: max(1, (foreground + 1) / 2)
        case .quarter: max(1, (foreground + 3) / 4)
        case .one: 1
        }
    }
}

/// Linux's vCPUs: the settings, and keeping the running VM in line with them.
///
/// The count changes through ACPI CPU hotplug, so Linux carries on throughout;
/// in the background, the cores they run on can change through the vCPU
/// threads' QoS (see `CoreClass`). Both follow whether the app is in front, and
/// take effect as soon as they are changed.
enum Vcpus {

    // MARK: The device

    /// The most there can be: one per core, and so is fixed for every snapshot
    /// on this device.
    static var maximum: Int { Int(qemu_max_vcpus()) }

    /// What Linux gets when nothing has been chosen.
    static var defaultCount: Int { min(4, maximum) }

    /// The device's performance and efficiency cores, where it says.
    static var coreClusters: (performance: Int, efficiency: Int)? {
        guard Sysctl.int("hw.nperflevels") == 2,
            let performance = Sysctl.int("hw.perflevel0.logicalcpu"),
            let efficiency = Sysctl.int("hw.perflevel1.logicalcpu")
        else {
            return nil
        }
        return (Int(performance), Int(efficiency))
    }

    // MARK: The settings

    /// How many in the foreground.
    static var foreground: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "vcpus")
            return stored == 0 ? defaultCount : min(max(stored, 1), maximum)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "vcpus")
            settingsChanged()
        }
    }

    /// How many of those in the background.
    static var backgroundShare: BackgroundShare {
        get {
            BackgroundShare(
                rawValue: UserDefaults.standard.string(forKey: "vcpus_background") ?? "") ?? .all
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "vcpus_background")
            settingsChanged()
        }
    }

    /// Where they run in the background.
    static var backgroundCores: CoreClass {
        get {
            CoreClass(
                rawValue: UserDefaults.standard.string(forKey: "vcpu_cores_background") ?? "")
                ?? .any
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "vcpu_cores_background")
            settingsChanged()
        }
    }

    /// The background's count, given the foreground's.
    static var background: Int { backgroundShare.count(of: foreground) }

    // MARK: The running VM

    /// Posted on the main queue when `present` or `isChanging` moves.
    static let stateDidChange = Notification.Name("io.ara.tctish.vcpus.stateDidChange")

    /// How many vCPUs Linux has now, as last seen, or nil before QEMU is up.
    /// Main thread.
    private(set) static var present: Int?

    /// Whether a change is under way. Main thread.
    private(set) static var isChanging = false

    /// Whether the app is in the background, as far as the vCPUs go. Main
    /// thread; set by the app delegate.
    private static var inBackground = false

    /// Whether Linux has come up far enough to be handed vCPUs: it hears of
    /// them over ACPI, and one plugged in before its ACPI is up is not seen.
    /// Set by the first shell, which is well past that, and cleared when Linux
    /// is started again.
    private static var guestReady = false

    /// What the change under way is working toward, read by the vCPU queue
    /// before every step, or 0 to stop at the next one.
    ///
    /// Atomic rather than handed over at the start, so that a change follows
    /// what is wanted as it goes: the setting moving, or the app going to the
    /// background, which stops it until the save is done.
    private static let goal = ManagedAtomic<Int>(0)

    /// How many more times a change that fell short is tried again by itself.
    /// Main thread.
    private static var retriesLeft = 0

    /// The background task a change made in the background runs under, so that
    /// iOS doesn't suspend the app in the middle of one. Main thread.
    private static var backgroundTask = UIBackgroundTaskIdentifier.invalid

    /// Where changes run, one at a time and off the main thread: an unplug
    /// waits for Linux to let the vCPU go.
    private static let queue = DispatchQueue(label: "io.ara.tctish.vcpus", qos: .userInitiated)

    /// How many are wanted now.
    static var wanted: Int { inBackground ? background : foreground }

    /// Where they are wanted now: in the foreground, always wherever iOS puts
    /// them.
    static var wantedCores: CoreClass { inBackground ? backgroundCores : .any }

    /// QEMU was started with `count`. From the boot queue.
    static func launched(with count: Int) {
        DispatchQueue.main.async {
            present = count
            NotificationCenter.default.post(name: stateDidChange, object: nil)
        }
    }

    /// The shell has connected, so Linux is up. Main thread.
    static func shellConnected() {
        guard !guestReady else { return }

        guestReady = true
        Log.qemu.note(
            "vcpus: linux is up, launched with \(present.map(String.init) ?? "?"), wants \(wanted)")
        applyCores()
        reconcile()
    }

    /// Linux is being started again, by a reset. Main thread.
    ///
    /// Nothing is plugged in or taken away until its shell is back: its ACPI
    /// has to be up to hear of it, and its init has to have installed the
    /// helper that brings a new vCPU online. An unplug that was still
    /// outstanding is forgotten, as the reset withdrew it.
    static func guestRestarting(qemu: QEMUInterface) {
        guestReady = false
        goal.store(0, ordering: .relaxed)
        queue.async { qemu.forgetOutstandingUnplug() }
    }

    /// The app has gone to the background. Main thread.
    ///
    /// Nothing changes yet, and a change under way stops at its next step: the
    /// save comes first, with the little time the background has. The
    /// background's vCPUs and cores follow once it is done, through
    /// `machineMayHaveChanged`.
    static func enteredBackground() {
        inBackground = true
        goal.store(0, ordering: .relaxed)
    }

    /// The app has come back to the foreground. Main thread.
    static func willEnterForeground() {
        inBackground = false
        applyCores()
        reconcile()
    }

    /// A save, a park or a return from one has finished, so the machine may be
    /// free to change again. Main thread.
    static func machineMayHaveChanged() {
        applyCores()
        reconcile()
    }

    /// One of the settings changed. Main thread.
    private static func settingsChanged() {
        applyCores()
        reconcile()
    }

    // MARK: Changing

    /// Puts the vCPU threads where they are wanted now.
    ///
    /// Asked of QEMU every time rather than when it differs, since this costs
    /// nothing, and a vCPU plugged in meanwhile starts in the class last asked
    /// for anyway.
    private static func applyCores() {
        qemu_vcpu_set_qos(wantedCores.qos)
    }

    /// How many times, and how far apart, a change that fell short is tried
    /// again: an unplug Linux is still finishing holds back plugging, and
    /// nothing else would come back to it.
    private static let retries = 3
    private static let retryDelay: TimeInterval = 5

    /// Brings the VM to the count wanted now, if it may be changed now.
    ///
    /// Always asks QEMU what there is rather than trusting `present`, which a
    /// late unplug or a snapshot loaded from inside Linux can leave behind.
    private static func reconcile(retrying: Bool = false) {
        guard guestReady, let app = UIApplication.shared.delegate as? AppDelegate,
            let qemu = app.qemu,
            // Saving, parked, or coming back from a park: what the VM has is in a snapshot or on
            // its way out of one. Whatever ends that calls `machineMayHaveChanged`.
            !app.machineIsAway
        else {
            goal.store(0, ordering: .relaxed)
            return
        }

        if !retrying { retriesLeft = retries }

        // A change under way picks this up at its next step.
        goal.store(wanted, ordering: .relaxed)
        guard !isChanging else { return }

        isChanging = true
        NotificationCenter.default.post(name: stateDidChange, object: nil)
        beginBackgroundTaskIfAway()

        queue.async {
            let now = qemu.changeVcpus(toward: {
                let target = goal.load(ordering: .relaxed)
                return target == 0 ? nil : target
            })

            DispatchQueue.main.async {
                isChanging = false
                if let now { present = now }
                NotificationCenter.default.post(name: stateDidChange, object: nil)
                endBackgroundTask()

                guard let now, now != wanted, retriesLeft > 0 else { return }
                retriesLeft -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
                    reconcile(retrying: true)
                }
            }
        }
    }

    private static func beginBackgroundTaskIfAway() {
        guard inBackground, backgroundTask == .invalid else { return }

        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Changing vCPUs") {
            // Out of time: stop at the next step, and let the task go.
            goal.store(0, ordering: .relaxed)
            endBackgroundTask()
        }
    }

    private static func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
