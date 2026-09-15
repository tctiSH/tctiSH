//
//  JitEnablement.swift
//  Decides how this launch will run QEMU, and arranges for it.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation

/// Works out whether this launch can JIT, and does whatever that takes.
///
/// The ordering here is forced and counter-intuitive: QEMU raises its blessing
/// traps **only** if it finds a debugger attached at the moment it allocates
/// its code buffer. The debugger therefore has to be in place _before_ QEMU
/// starts. The helper call that attaches it does not return until QEMU releases
/// the debugger, which cannot happen until QEMU has started.
///
/// So the host issues the call, waits for the *attach* rather than the call,
/// and boots QEMU while the helper is still blocked inside it.
///
/// This all happens off the main thread as `prepareForBoot()` blocks for as
/// long as the attach takes and the window cannot be drawn until the app
/// delegate returns.
enum JitEnablement {

    /// How this launch ended up running.
    enum Outcome {

        /// TXM device with a debugger attached: QEMU JITs, hands each code
        /// region over to be blessed as it allocates it, and lets the debugger
        /// go once the last one is ready.
        case blessed

        /// Pre-TXM device: convincing the process it is debugged is enough.
        case ptrace

        /// No JIT this launch.
        case interpreted(Reason)

        /// Why JIT isn't running.
        enum Reason: Equatable {

            /// The user turned it off.
            case disabledInSettings

            /// The IORegistry wouldn't say whether TXM is present.
            case txmUnknown

            /// A pre-TXM device where the ptrace hack didn't take.
            case ptraceRefused

            /// No LocalDevVPN tunnel, so no way to reach a debugger.
            case noTunnel

            /// Nothing at `JitPairingFile.url`.
            case noPairingFile

            /// The helper never attached within `attachDeadline`.
            case attachTimedOut

            var logDescription: String {
                switch self {
                case .disabledInSettings: return "JIT is turned off in settings"
                case .txmUnknown: return "could not tell whether TXM is present"
                case .ptraceRefused: return "the ptrace hack was refused"
                case .noTunnel: return "no LocalDevVPN tunnel"
                case .noPairingFile: return "no pairing file at \(JitPairingFile.url.path)"
                case .attachTimedOut:
                    return String(format: "no debugger attached within %.0fs", attachDeadline)
                }
            }

            /// What the status pill says. Has to fit in a capsule, so the
            /// detail stays in `logDescription` where there is room for it.
            var statusMessage: String {
                switch self {
                case .disabledInSettings: return "JIT off in settings"
                case .txmUnknown: return "JIT support unclear"
                case .ptraceRefused: return "JIT refused"
                case .noTunnel: return "No debug tunnel"
                case .noPairingFile: return "No pairing file"
                case .attachTimedOut: return "Debugger didn't attach"
                }
            }

            /// The symbol shown beside it.
            var statusSymbol: String {
                switch self {
                case .txmUnknown:
                    // Distinct from the rest on purpose. The others mean JIT isn't set up, which is
                    // ordinary; this one means the device wouldn't answer a question it should
                    // have, which isn't.
                    return "exclamationmark.triangle.fill"
                default:
                    return "tortoise.fill"
                }
            }
        }

        /// How this outcome reads in the status pill.
        var status: (message: String, symbol: String) {
            switch self {
            case .blessed, .ptrace: return ("JIT enabled", "hare.fill")
            case .interpreted(let reason): return (reason.statusMessage, reason.statusSymbol)
            }
        }
    }

    /// What `prepareForBoot()` settled on, or nil while it is still deciding.
    ///
    /// The decision is made on a background queue, so the UI is on screen
    /// before there is an answer.
    private(set) static var outcome: Outcome?

    /// Whether JIT is still being arranged.
    private(set) static var isEnabling = false

    /// Posted on the main queue when either of the two above changes.
    static let stateDidChange = Notification.Name("io.ara.tctish.jit.stateDidChange")

    /// True when a helper is attaching a debugger that QEMU will trap into.
    private(set) static var expectsFreeze = false

    /// What the banner says while JIT is being arranged.
    static let preparingMessage = "Preparing JIT…"

    /// What the blocking banner should say, or nil if it should not be up.
    static var bannerMessage: String? {
        switch outcome {
        case nil: return preparingMessage
        case .blessed: return isEnabling ? preparingMessage : nil
        case .ptrace, .interpreted: return nil
        }
    }

    /// How long to wait for the debugger to attach before giving up.
    static let attachDeadline: TimeInterval = 5

    /// How often to look for the debugger while waiting.
    private static let attachPollInterval: TimeInterval = 0.025

    /// Settles how QEMU will run and sets the gates it reads on startup.
    ///
    /// Must be called before `startQemuThread()`, and never on the main thread:
    /// on the TXM path it blocks for as long as it takes the debugger to
    /// attach, up to `attachDeadline`.
    @discardableResult
    static func prepareForBoot() -> Outcome {
        let outcome = decide()
        publish(outcome)

        switch outcome {
        case .blessed:
            AppDelegate.usingJitHacks = true
            AppDelegate.blessJitRegions = true
            Log.jit.note("JIT enabled; QEMU will hand its code buffer to the debugger")

        case .ptrace:
            AppDelegate.usingJitHacks = true
            AppDelegate.blessJitRegions = false
            Log.jit.note("JIT enabled via the ptrace hack")

        case .interpreted(let reason):
            AppDelegate.usingJitHacks = false
            AppDelegate.blessJitRegions = false
            Log.jit.note("running under TCTI -- \(reason.logDescription)")
        }

        return outcome
    }

    /// Hands the verdict to the UI.
    private static func publish(_ value: Outcome) {
        DispatchQueue.main.async {
            outcome = value
            NotificationCenter.default.post(name: stateDidChange, object: nil)
        }
    }

    /// Says whether enablement is still running. Same queue, same reason.
    private static func publish(isEnabling value: Bool) {
        DispatchQueue.main.async {
            isEnabling = value
            NotificationCenter.default.post(name: stateDidChange, object: nil)
        }
    }

    // MARK: - The decision

    private static func decide() -> Outcome {
        guard UserDefaults.standard.string(forKey: "jit_mode") == "jit_when_possible" else {
            return .interpreted(.disabledInSettings)
        }

        #if targetEnvironment(macCatalyst)
            // Catalyst gets JIT from its entitlements. Nothing to arrange, and nothing to bless.
            return .ptrace
        #else
            let txm = TxmPresence.current
            Log.jit.note("TXM \(txm.description)")

            switch txm {
            case .absent:
                // The pre-TXM world, unchanged: a process that believes it is being debugged may
                // map its own pages executable, and no second process need be involved at all.
                return set_up_jit()
                    ? .ptrace
                    : .interpreted(.ptraceRefused)

            case .unknown:
                // StikJIT refuses to guess here, and guessing wrong is expensive in both directions
                // -- a trap nobody answers, or a debugger waiting on a trap that never comes.
                // Decline in step with it.
                return .interpreted(.txmUnknown)

            case .present:
                return enableUnderTxm()
            }
        #endif
    }

    /// The TXM path: JIT is only possible with help from another process.
    ///
    /// Note what is *not* here -- `set_up_jit()` is never called. Under TXM the
    /// ptrace hack cannot grant JIT anyway, and it actively gets in the way: a
    /// self-traced process cannot be attached to, so calling it would lock out
    /// the very debugger we are trying to invite in.
    private static func enableUnderTxm() -> Outcome {
        // Already traced -- Xcode, most likely. Whatever is attached owns the trap; under Xcode
        // that is the jit-bless stop hook (see utils/jit-bless), and a second debugger could not
        // attach in any case.
        if jit_debugger_tracing() {
            // Deliberately without raising the banner. That debugger is the developer's, the
            // blessing is jit-bless's ~15s rather than StikJIT's ~1.7s, and someone watching
            // /tmp/jit-bless.log does not need the screen taken away from them to be told it is
            // working.
            Log.jit.note("a debugger is already attached; leaving the region to it")
            return .blessed
        }

        guard TunnelProbe.probeAndReport().isAvailable else {
            return .interpreted(.noTunnel)
        }

        guard let pairingData = JitPairingFile.read() else {
            // Asking for one needs a window, which does not exist yet. The UI picks this up once it
            // has somewhere to put the picker.
            needsPairingFile = true
            return .interpreted(.noPairingFile)
        }

        return attach(pairingData: pairingData)
    }

    /// Asks the helper to attach, and waits for it to land.
    private static func attach(pairingData: Data) -> Outcome {
        let started = Date()

        // Set if `enable` comes back having done nothing, which it can do long before the deadline.
        // An unmounted developer disk image is declined in about the time one tunnel handshake
        // takes.
        let declined = Latch()

        // From here until the helper answers, JIT is being arranged. The tail of that is QEMU's
        // code buffer being blessed with every thread in this process stopped. Both flags exist to
        // get something on screen before that happens.
        expectsFreeze = true
        publish(isEnabling: true)

        // `enable` returns only once QEMU has had every region blessed and released the debugger,
        // none of which can happen until QEMU is running, which itself cannot happen until this
        // returns.
        JITHelperClient.enable(pairingData: pairingData, targetPID: getpid()) { reply in
            publish(isEnabling: false)

            guard let reply, reply.outcome == .succeeded else {
                declined.close()

                // Much the commonest reason is an unmounted developer disk image, and fixing that
                // takes a network and minutes. Start it now so that the next launch can take the
                // fast path.
                prepareInBackground(pairingData: pairingData)
                return
            }
        }

        guard waitForDebugger(unless: declined) else {
            // The helper may yet attach after this, and if it does it will wait for a trap that a
            // TCTI boot never raises. Nothing here can call it off; it is logged so that it can be
            // recognized on a device rather than puzzled over.
            return .interpreted(.attachTimedOut)
        }

        Log.jit.note(
            String(
                format: "debugger attached after %.2fs",
                Date().timeIntervalSince(started)))
        return .blessed
    }

    /// Blocks until a debugger attaches, the helper gives up, or time runs out.
    ///
    /// Polls `P_TRACED` and not `CS_DEBUGGED`: the former is exactly what QEMU
    /// tests before trapping, while the latter is sticky and would report an
    /// attach from earlier in this process's life as though it were this one.
    ///
    /// Giving up early matters more than it looks. The first launch on any
    /// device has no developer disk image, so `enable` declines almost at once
    /// -- and without this the launch would sit here for the whole deadline
    /// waiting for an attach that is never coming.
    private static func waitForDebugger(unless declined: Latch) -> Bool {
        let deadline = Date().addingTimeInterval(attachDeadline)

        while Date() < deadline {
            if jit_debugger_tracing() {
                return true
            }

            if declined.isClosed {
                Log.jit.note("the helper declined, so not waiting out the deadline")
                return false
            }

            Thread.sleep(forTimeInterval: attachPollInterval)
        }

        return jit_debugger_tracing()
    }

    /// Downloads and mounts the developer disk image, for next time.
    ///
    /// Nothing waits on this: by the time it runs the VM is already booting
    /// under TCTI. A device's first launch is therefore always JITless by
    /// design -- preparation wants a network and minutes of it, and holding a
    /// launch open for that would be worse than booting slow.
    private static func prepareInBackground(pairingData: Data) {
        Log.jit.note("preparing the device in the background, for the next launch")
        setPreparation(.running(message: "Getting DDI", fraction: nil))

        // In-process, so it can say how it's getting on as it goes. Blocking, hence the queue.
        DispatchQueue.global(qos: .utility).async {
            let outcome = DdiPreparation.run(pairingData: pairingData) { message, fraction in
                setPreparation(.running(message: message, fraction: fraction))
            }

            switch outcome {
            case .ready:
                Log.jit.note("device prepared")
                setPreparation(.finished(succeeded: true, message: "Relaunch for JIT"))
            case .failed(let reason):
                Log.jit.note("could not prepare the device -- \(reason)")
                setPreparation(.finished(succeeded: false, message: "Couldn't get DDI"))
            }
        }
    }

    // MARK: - What the UI needs to know

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

    /// Set when JIT was possible but for the want of a pairing file.
    ///
    /// The launch path cannot ask for one -- `UIDocumentPickerViewController`
    /// needs a window, and at this point there isn't one -- so it records the
    /// fact and leaves the asking to whoever has a window.
    private(set) static var needsPairingFile = false

    /// What background preparation is doing, if anything.
    enum Preparation: Equatable {
        case idle

        /// `fraction` is nil only while there is genuinely nothing to measure
        /// -- before the first byte arrives, or when a server declines to say
        /// how big a file is. A bar that can't be drawn is better left undrawn.
        case running(message: String, fraction: Double?)

        case finished(succeeded: Bool, message: String)
    }

    /// Posted on the main queue whenever `preparation` changes.
    static let preparationDidChange = Notification.Name("io.ara.tctish.jit.preparationDidChange")

    private(set) static var preparation: Preparation = .idle

    private static func setPreparation(_ value: Preparation) {
        DispatchQueue.main.async {
            guard preparation != value else { return }
            preparation = value
            NotificationCenter.default.post(name: preparationDidChange, object: nil)
        }
    }

    /// Called once a pairing file has been imported after launch.
    ///
    /// Far too late to help this boot -- QEMU allocated its code buffer long
    /// ago -- so all this can do is get the device ready for the next one.
    static func pairingFileArrived() {
        needsPairingFile = false

        guard let pairingData = JitPairingFile.read() else { return }
        prepareInBackground(pairingData: pairingData)
    }
}
