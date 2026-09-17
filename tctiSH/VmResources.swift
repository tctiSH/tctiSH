//
//  VmResources.swift
//  The two sizes the user gets to choose: guest RAM, and the TCG code cache.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation

/// Renders sizes held in MiB.
///
/// MiB because that is the unit QEMU's `tb-size` takes, and keeping one unit
/// end to end avoids a class of conversion bug that would only ever show up as
/// a mysteriously wrong allocation.
enum Mebibytes {

    /// How a size reads in the settings screen.
    static func describe(_ mib: Int) -> String {
        guard mib >= 1024 else { return "\(mib) MiB" }

        if mib % 1024 == 0 {
            return "\(mib / 1024) GiB"
        }

        // The code-cache ladder steps in half-gibibytes, so 1536 has to read as "1.5 GiB" rather
        // than as "1536 MiB" sitting incongruously between two GiB entries.
        return "\(Double(mib) / 1024) GiB"
    }

    /// How a size reads as a QEMU size argument.
    static func qemuArgument(_ mib: Int) -> String {
        mib % 1024 == 0 ? "\(mib / 1024)G" : "\(mib)M"
    }

    /// Parses a QEMU size argument back to MiB, or nil if it isn't one.
    ///
    /// Only the two suffixes this app has ever written are accepted. QEMU's own
    /// parser is far more generous, but anything else in our setting came from
    /// somewhere unexpected and is better rejected.
    static func parse(qemuArgument: String) -> Int? {
        let text = qemuArgument.uppercased()

        if let digits = text.dropSuffixIfPresent("G"), let value = Int(digits) {
            return value * 1024
        }
        if let digits = text.dropSuffixIfPresent("M"), let value = Int(digits) {
            return value
        }

        return Int(text)
    }

    /// How much RAM this device has, by the same mechanism used by QEMU.
    static var hostPhysicalMemory: Int {
        let pages = sysconf(_SC_PHYS_PAGES)
        guard pages > 0 else { return 0 }

        return Int(pages) * Int(getpagesize())
    }
}

extension String {
    /// The receiver without `suffix`, or nil if it didn't end in it.
    fileprivate func dropSuffixIfPresent(_ suffix: String) -> String? {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : nil
    }
}

// MARK: - Guest RAM

/// How much memory the guest is given.
///
/// Stored as the QEMU `-m` argument rather than as a number, because that is
/// what this setting has always held and what `last_memory` is compared
/// against.
enum VmMemory {

    /// Every amount offered, smallest first.
    static let sizes = [
        256, 512, 1024, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768,
    ]

    /// What the guest gets when nothing has been chosen.
    static let defaultSize = 1024

    // MARK: What is safe to offer

    /// Set aside for iOS, the app outside QEMU, and the terminal, estimated.
    private static let reservedForTheSystem = 1536

    /// The largest amount worth recommending on this device.
    ///
    /// Two limits, whichever is encountered first:
    ///
    /// * **Half of Physical RAM:** Guest pages are committed lazily, so `-m 8G`
    ///   does not cost 8 GiB on the spot, but a guest that runs for a while
    ///   fills its page cache and drifts toward the limit anyway, so the ceiling
    ///   has to be picked as though it will.
    /// * **Remaining After System and Code Cache.** The code cache is the term
    ///   that makes this worth computing rather than hard-coding: under TXM
    ///   every page of it is written during blessing, so it is fully resident
    ///   from the moment the VM starts. Choosing a 2 GiB cache really does take
    ///   2 GiB away from what the guest can safely be given, and the point of
    ///   splitting these two settings is that the menu now says so.
    static var recommendedCeiling: Int {
        recommendedCeiling(blessed: CodeCache.blessingExpected)
    }

    /// The same, for a stated JIT arrangement rather than the expected one.
    ///
    /// Parameterised so the screen can show both. They differ by the whole of
    /// the code cache.
    static func recommendedCeiling(blessed: Bool) -> Int {
        let physical = Mebibytes.hostPhysicalMemory / (1024 * 1024)

        // A device that won't say how much memory it has is not a device to make confident
        // recommendations about.
        guard physical > 0 else { return defaultSize }

        let half = physical / 2
        let remaining = physical - reservedForTheSystem - CodeCache.residentSize(blessed: blessed)

        // Never recommend nothing at all: a device tight enough to fail both tests can still run
        // the smallest guest we offer, and an empty "recommended" section would read as a bug.
        let limit = max(sizes[0], min(half, remaining))

        // Rounded down to an amount actually on the menu. This is shown to the user as the boundary
        // between the two lists.
        return sizes.last { $0 <= limit } ?? sizes[0]
    }

    /// The amounts shown in the main list.
    static var recommended: [Int] {
        let ceiling = recommendedCeiling
        return sizes.filter { $0 <= ceiling }
    }

    /// The amounts shown behind the overflow, which carries a warning.
    static var beyondRecommended: [Int] {
        let ceiling = recommendedCeiling
        return sizes.filter { $0 > ceiling }
    }

    // MARK: The setting

    /// The chosen size, in MiB.
    static var selected: Int {
        get {
            guard let stored = UserDefaults.standard.string(forKey: "memory"),
                let mib = Mebibytes.parse(qemuArgument: stored)
            else {
                return defaultSize
            }

            return mib
        }
        set {
            UserDefaults.standard.set(Mebibytes.qemuArgument(newValue), forKey: "memory")
        }
    }

    /// What to hand QEMU as `-m`.
    static var qemuArgument: String {
        Mebibytes.qemuArgument(selected)
    }

    /// What the VM was last actually booted with.
    private static var lastBooted: Int {
        guard let stored = UserDefaults.standard.string(forKey: "last_memory"),
            let mib = Mebibytes.parse(qemuArgument: stored)
        else {
            return defaultSize
        }

        return mib
    }

    /// Whether the setting has moved since the last boot.
    ///
    /// A changed value forces a cold boot: guest RAM size is part of the
    /// migration stream, so a snapshot taken at one size cannot be loaded at
    /// another.
    static var changedSinceLastBoot: Bool {
        selected != lastBooted
    }

    /// Records what we are booting with, for the next launch to compare
    /// against.
    static func recordBooted() {
        UserDefaults.standard.set(qemuArgument, forKey: "last_memory")
    }
}

// MARK: - Code cache

/// How large TCG's translation buffer is allowed to be.
///
/// TCTI generates its bytecode into this buffer exactly as JIT generates native
/// code into it (`alloc_code_gen_buffer` is reached either way) so a buffer too
/// small for the working set means the same repeated flush-and-retranslate
/// regardless of the execution mode.
///
/// What differs is only what it costs up front, and that is blessing. Where
/// blessing applies, every page is written before the guest starts
/// (`utils/jit-bless/jit_bless.py:160`), which is both a launch latency and a
/// block of memory resident for the whole session. Where it does not (TCTI, or
/// the pre-TXM ptrace path, neither of which reaches
/// `alloc_code_gen_buffer_splitwx`) the mapping is ordinary lazy anonymous
/// memory and costs only what the guest actually fills.
enum CodeCache {

    /// When the cache is paid for.
    enum Mode: String {

        /// Exactly `ceiling`, taken in full at startup.
        case fixed

        /// Start small and grow towards `ceiling` as the guest needs it.
        case dynamic
    }

    // MARK: The ladder

    /// The sizes offered for Fixed, and the ceilings offered for Dynamic.
    ///
    /// Stops at 2 GiB because that is where QEMU stops:
    /// `MAX_CODE_GEN_BUFFER_SIZE` is 2 GiB on aarch64
    /// (`accel/tcg/translate-all.c:920`), and `size_code_gen_buffer()` clamps
    /// to it silently.
    static let sizes = [512, 1024, 1536, 2048]

    /// The sizes Dynamic steps through, in MiB.
    ///
    /// Doubling at first and then in half-gibibytes. The first rung has to make
    /// the launch cheap and has to be small enough that a busy guest actually
    /// fills it. By the time two expansions have been agreed to the guest is
    /// clearly doing something heavy, and being asked again every 128 MiB would
    /// be worse than paying for a bigger jump less often.
    ///
    /// The rungs are a judgement about how much freeze is worth how much
    /// headroom, and a formula would hide that behind arithmetic that looks
    /// more principled than it is.
    static let growthLadder = [128, 256, 512, 1024, 1536, 2048]

    /// Where Dynamic starts.
    static var dynamicInitial: Int { growthLadder.first ?? 128 }

    /// Stored in place of a size to mean "whatever QEMU would have picked".
    ///
    /// Zero rather than an optional in the defaults, because `UserDefaults`
    /// gives back zero for a key it has never seen, and that is exactly what
    /// this should mean for a fresh install.
    static let autoCeiling = 0

    // MARK: Auto

    /// What QEMU's own heuristic comes to on this device.
    ///
    /// `size_code_gen_buffer()` with `tb_size == 0`
    /// (`accel/tcg/translate-all.c:964`): an eighth of host RAM, capped at 1
    /// GiB -- so it never reaches the 2 GiB ceiling however large the device,
    /// which is why Auto is the cheap option rather than the generous one.
    ///
    /// Reproduced here rather than asked of QEMU because settings has to show
    /// the number even when there may not be a VM to ask.
    static var autoSize: Int {
        let physical = Mebibytes.hostPhysicalMemory / (1024 * 1024)

        // DEFAULT_CODE_GEN_BUFFER_SIZE, after its own MIN against the aarch64 maximum.
        let uncapped = 1024

        let chosen = physical > 0 ? min(uncapped, physical / 8) : uncapped

        // MIN_CODE_GEN_BUFFER_SIZE and MAX_CODE_GEN_BUFFER_SIZE respectively.
        return max(1, min(chosen, 2048))
    }

    // MARK: The setting

    static var mode: Mode {
        get {
            let stored = UserDefaults.standard.string(forKey: "code_cache_mode") ?? ""
            return Mode(rawValue: stored) ?? .fixed
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "code_cache_mode")
        }
    }

    /// The size chosen, or nil for "whatever QEMU would have picked".
    ///
    /// One stored value for both modes, because they mean the same thing -- how
    /// large the cache may ever get -- so switching between them doesn't
    /// silently discard the size just picked.
    static var chosenCeiling: Int? {
        get {
            let stored = UserDefaults.standard.integer(forKey: "code_cache_ceiling")
            return sizes.contains(stored) ? stored : nil
        }
        set {
            UserDefaults.standard.set(newValue ?? autoCeiling, forKey: "code_cache_ceiling")
        }
    }

    /// The ceiling actually in force, in MiB.
    static var ceiling: Int {
        chosenCeiling ?? autoSize
    }

    /// Whether the ceiling is being left to QEMU's own heuristic.
    static var ceilingIsAutomatic: Bool {
        chosenCeiling == nil
    }

    /// How large a buffer QEMU maps.
    static var allocationSize: Int {
        sizes.last ?? 2048
    }

    /// How much of that mapped buffer QEMU prepares at boot, in MiB.
    static var initialSize: Int {
        switch mode {
        case .fixed: return ceiling
        case .dynamic: return min(dynamicInitial, ceiling)
        }
    }

    /// Whether the next launch is expected to have to bless the cache.
    ///
    /// Deliberately not `JitEnablement.outcome`: that describes the launch
    /// already running, and these settings apply to the next one.
    static var blessingExpected: Bool {
        guard UserDefaults.standard.string(forKey: "jit_mode") == "jit_when_possible" else {
            return false
        }

        return txmPresent
    }

    /// Cached, because the IORegistry's answer cannot change while the app is
    /// running and this is read every time a settings list is rebuilt.
    private static let txmPresent = TxmPresence.current.isPresent ?? true

    /// How much memory the cache costs up front, blessed or not.
    ///
    /// The initial size rather than the ceiling, because that is what is taken
    /// at boot. Dynamic's whole purpose is that its ceiling costs nothing until
    /// it is reached.
    static func residentSize(blessed: Bool) -> Int {
        blessed ? initialSize : 0
    }

    /// What to hand QEMU as the `tb-size` accelerator property, in MiB.
    static var tbSizeArgument: Int {
        allocationSize
    }

    /// How this setting reads in a single line, for a settings row or the log.
    static var summary: String {
        let size = Mebibytes.describe(ceiling)

        switch mode {
        case .fixed:
            return ceilingIsAutomatic ? "Auto, \(size)" : size
        case .dynamic:
            return ceilingIsAutomatic ? "Dynamic, auto (\(size))" : "Dynamic, up to \(size)"
        }
    }

    // MARK: Change detection

    /// What the VM was last actually booted with.
    static var bootSignature: String {
        "\(allocationSize)/\(initialSize)"
    }

    private static var lastBooted: String {
        UserDefaults.standard.string(forKey: "last_code_cache") ?? bootSignature
    }

    /// Whether the size has moved since the last boot.
    ///
    /// Unlike guest RAM this does not invalidate a snapshot, so nothing forces
    /// a cold boot here. It is tracked so that the UI can say the change hasn't
    /// taken effect yet.
    static var changedSinceLastBoot: Bool {
        bootSignature != lastBooted
    }

    /// Records what we are booting with, for the next launch to compare
    /// against.
    static func recordBooted() {
        UserDefaults.standard.set(bootSignature, forKey: "last_code_cache")
    }
}

// MARK: - The plain settings

/// The settings that are simply stored and read back.
enum AppSetting: String {
    case resumeBehavior = "resume_behavior"
    case bootSnapshot = "boot_snapshot"
    case diskName = "disk_name"
    case jitMode = "jit_mode"
    case fontSize = "font_size"
    case codeCacheNotifications = "code_cache_notifications"

    var string: String {
        UserDefaults.standard.string(forKey: rawValue) ?? ""
    }

    var integer: Int {
        UserDefaults.standard.integer(forKey: rawValue)
    }

    var bool: Bool {
        UserDefaults.standard.bool(forKey: rawValue)
    }

    func set(_ value: String) {
        UserDefaults.standard.set(value, forKey: rawValue)
    }

    func set(_ value: Int) {
        UserDefaults.standard.set(value, forKey: rawValue)
    }

    func set(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: rawValue)
    }
}
