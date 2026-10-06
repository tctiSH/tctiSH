//
//  SystemInfo.swift
//  What this device is, for the System Info debug page.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import UIKit

/// A report on the device: model, CPU, memory, storage and the CPU features
/// QEMU cares about.
struct SystemInfo {

    struct Section {
        var title: String
        var rows: [(label: String, value: String)]
    }

    var sections: [Section]

    static func gather() -> SystemInfo {
        SystemInfo(sections: [
            device(), cpu(), memory(), storage(), qemu(), featureSection(features()),
        ])
    }

    /// The whole report as text, for sharing and for the log.
    var text: String {
        sections.map { section in
            section.title + "\n"
                + section.rows.map { "  \($0.label): \($0.value)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Sections

    private static func device() -> Section {
        let device = UIDevice.current
        let build = Sysctl.string("kern.osversion").map { " (\($0))" } ?? ""

        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }

        return Section(
            title: "Device",
            rows: [
                ("Model", Sysctl.string("hw.machine") ?? "Unknown"),
                ("Board", Sysctl.string("hw.model") ?? "Unknown"),
                ("System", "\(device.systemName) \(device.systemVersion)\(build)"),
                ("Kernel", Sysctl.string("kern.osrelease") ?? "Unknown"),
                ("Thermal State", thermal),
                (
                    "Low Power Mode",
                    ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off"
                ),
            ])
    }

    private static func cpu() -> Section {
        var rows: [(String, String)] = [
            ("Name", Sysctl.string("machdep.cpu.brand_string") ?? familyName() ?? "Not reported")
        ]

        // Core clusters, fastest first: "Performance", "Efficiency".
        let levels = Int(Sysctl.int("hw.nperflevels") ?? 0)
        var clusters: [String] = []
        for level in 0..<levels {
            let prefix = "hw.perflevel\(level)"
            let name = Sysctl.string("\(prefix).name") ?? "Level \(level)"
            let cores = Sysctl.int("\(prefix).physicalcpu") ?? 0
            clusters.append("\(cores) \(name.lowercased())")

            let caches = [
                ("L1i", Sysctl.int("\(prefix).l1icachesize")),
                ("L1d", Sysctl.int("\(prefix).l1dcachesize")),
                ("L2", Sysctl.int("\(prefix).l2cachesize")),
            ].compactMap { label, size in size.map { "\(label) \(bytes($0))" } }
            rows.append(("\(name) Caches", caches.joined(separator: ", ")))
        }

        let total = Sysctl.int("hw.physicalcpu") ?? Int64(ProcessInfo.processInfo.processorCount)
        rows.insert(
            (
                "Cores",
                clusters.isEmpty ? "\(total)" : "\(total) (\(clusters.joined(separator: ", ")))"
            ), at: 1)

        if let tb = Sysctl.int("hw.tbfrequency") {
            rows.append(("Timebase", String(format: "%.1f MHz", Double(tb) / 1e6)))
        }
        if let family = Sysctl.int("hw.cpufamily") {
            let sub = Sysctl.int("hw.cpusubfamily").map { ", subfamily \($0)" } ?? ""
            rows.append(
                ("Family", String(format: "0x%08x", UInt32(truncatingIfNeeded: family)) + sub))
        }
        if let line = Sysctl.int("hw.cachelinesize") {
            rows.append(("Cache Line", "\(line) bytes"))
        }
        if let page = Sysctl.int("vm.pagesize") ?? Sysctl.int("hw.pagesize") {
            rows.append(("Page Size", bytes(page)))
        }
        return Section(title: "CPU", rows: rows)
    }

    private static func memory() -> Section {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        let available = os_proc_available_memory()
        return Section(
            title: "Memory",
            rows: [
                ("Physical", bytes(Int64(ProcessInfo.processInfo.physicalMemory))),
                // Headroom now: the jetsam limit less the footprint below.
                ("Available to tctiSH", bytes(Int64(available))),
                (
                    "tctiSH Footprint",
                    kr == KERN_SUCCESS ? bytes(Int64(info.phys_footprint)) : "Unknown"
                ),
                (
                    "tctiSH Limit",
                    kr == KERN_SUCCESS
                        ? bytes(Int64(available + Int(info.phys_footprint))) : "Unknown"
                ),
            ])
    }

    private static func storage() -> Section {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
        ]
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys)

        return Section(
            title: "Storage",
            rows: [
                ("Capacity", values?.volumeTotalCapacity.map { bytes(Int64($0)) } ?? "Unknown"),
                (
                    "Available",
                    values?.volumeAvailableCapacityForImportantUsage.map { bytes($0) } ?? "Unknown"
                ),
                (
                    "Available (Opportunistic)",
                    values?.volumeAvailableCapacityForOpportunisticUsage.map { bytes($0) }
                        ?? "Unknown"
                ),
            ])
    }

    /// What the features mean for QEMU's code paths. Read here exactly as
    /// util/cpuinfo-aarch64.c reads them, by name, whatever the walk managed:
    /// QEMU takes a failed read as "absent", so this says when one fails.
    private static func qemu() -> Section {
        let lse2 = Sysctl.feature("hw.optional.arm.FEAT_LSE2")
        let lrcpc = Sysctl.feature("hw.optional.arm.FEAT_LRCPC")

        func state(_ features: [Sysctl.Feature]) -> String {
            if let failed = features.first(where: { $0.error != nil }) {
                return "Inactive: \(failed.shown)"
            }
            return features.allSatisfy { $0.value != 0 } ? "Active" : "Inactive"
        }

        return Section(
            title: "QEMU",
            rows: [
                ("LSE Atomics (LSE)", Sysctl.feature("hw.optional.arm.FEAT_LSE").shown),
                ("Ordered Guest Accesses (LRCPC, LSE2)", state([lrcpc, lse2])),
                ("128-bit TCTI Loads and Stores (LSE2)", state([lse2])),
                ("x86-Style Float Mode (AFP)", Sysctl.feature("hw.optional.arm.FEAT_AFP").shown),
            ])
    }

    private static func featureSection(_ features: (walked: Bool, list: [Sysctl.Feature]))
        -> Section
    {
        var rows: [(String, String)] = [
            (
                "Source",
                features.walked
                    ? "Every sysctl under hw.optional"
                    : "Known names (the sysctl walk is blocked)"
            )
        ]
        rows += features.list.map { feature in
            let short = feature.name.replacingOccurrences(of: "hw.optional.arm.", with: "")
                .replacingOccurrences(of: "hw.optional.", with: "")
            return (short, feature.shown)
        }
        return Section(title: "CPU Features", rows: rows)
    }

    // MARK: Helpers

    /// Every integer under hw.optional, FEAT_ flags first, then the rest, by
    /// name; or, where the sandbox refuses the walk, the known names one by
    /// one.
    private static func features() -> (walked: Bool, list: [Sysctl.Feature]) {
        final class Found {
            var entries: [Sysctl.Feature] = []
        }
        let found = Found()
        _ = system_probe_sysctls(
            "hw.optional",
            { name, value, context in
                guard let name, let context else { return }
                let found = Unmanaged<Found>.fromOpaque(context).takeUnretainedValue()
                found.entries.append(
                    Sysctl.Feature(name: String(cString: name), value: value, error: nil))
            }, Unmanaged.passUnretained(found).toOpaque())

        let walked = !found.entries.isEmpty
        let list = walked ? found.entries : Sysctl.knownFeatures.map(Sysctl.feature)
        return (
            walked,
            list.sorted { a, b in
                let aFeat = a.name.contains(".FEAT_"), bFeat = b.name.contains(".FEAT_")
                return aFeat != bFeat ? aFeat : a.name < b.name
            }
        )
    }

    /// iOS reports no brand string, so name the core design from hw.cpufamily,
    /// as the SDK's mach/machine.h spells it.
    private static func familyName() -> String? {
        let names: [UInt32: String] = [
            0x1b58_8bb3: "Firestorm and Icestorm",
            0xda33_d83d: "Avalanche and Blizzard",
            0x8765_edea: "Everest and Sawtooth",
            0xfa33_415e: "Ibiza",
            0x7201_5832: "Palma",
            0x2876_f5b5: "Coll",
            0x5f4d_ea93: "Lobos",
            0x6f51_29ac: "Donan",
            0x17d5_b93a: "Brava",
            0x75d4_acb9: "Tahiti",
            0x2045_26d0: "Tupai",
            0x1d5a_87e8: "Hidra",
            0xf76c_5b1a: "Sotra",
            0xab34_5f09: "Thera",
            0x01d7_a72b: "Tilos",
            0x6d0c_cb0c: "Komodo",
            0x7db5_6df1: "Borneo",
            0x3765_2b0c: "Nevis",
        ]
        guard let family = Sysctl.int("hw.cpufamily"),
            let name = names[UInt32(truncatingIfNeeded: family)]
        else { return nil }
        return "Apple \(name)"
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }
}

/// Reading sysctls by name.
enum Sysctl {

    /// A feature flag, or why it couldn't be read.
    struct Feature {
        var name: String
        var value: Int64
        var error: Int32?

        var shown: String {
            if let error { return "Unreadable (\(String(cString: strerror(error))))" }
            return value == 0 ? "No" : value == 1 ? "Yes" : "\(value)"
        }
    }

    /// Reads one feature flag, keeping the error rather than calling it absent.
    static func feature(_ name: String) -> Feature {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            // A name this kernel doesn't know is a feature it doesn't have.
            return Feature(name: name, value: 0, error: errno == ENOENT ? nil : errno)
        }
        return Feature(
            name: name, value: size == 4 ? Int64(Int32(truncatingIfNeeded: value)) : value,
            error: nil)
    }

    /// The hw.optional names macOS 27 lists on an M2 Max, for when the walk is
    /// refused. A device can have flags this lacks; the walk finds those.
    static let knownFeatures: [String] =
        ("arm.FEAT_FP8 arm.FEAT_CRC32 arm.FEAT_FlagM arm.FEAT_FlagM2 arm.FEAT_FHM arm.FEAT_DotProd "
        + "arm.FEAT_SHA3 arm.FEAT_RDM arm.FEAT_LSE arm.FEAT_SHA256 arm.FEAT_SHA512 arm.FEAT_SHA1 "
        + "arm.FEAT_AES arm.FEAT_PMULL arm.FEAT_SPECRES arm.FEAT_SPECRES2 arm.FEAT_SB "
        + "arm.FEAT_FRINTTS arm.FEAT_PACIMP arm.FEAT_LRCPC arm.FEAT_LRCPC2 arm.FEAT_LRCPC3 "
        + "arm.FEAT_FCMA arm.FEAT_JSCVT arm.FEAT_PAuth arm.FEAT_PAuth2 arm.FEAT_FPAC "
        + "arm.FEAT_FPACCOMBINE arm.FEAT_PAuth_LR arm.FEAT_DPB arm.FEAT_DPB2 arm.FEAT_BF16 "
        + "arm.FEAT_EBF16 arm.FEAT_I8MM arm.FEAT_WFxT arm.FEAT_RPRES arm.FEAT_CSSC arm.FEAT_HBC "
        + "arm.FEAT_LUT arm.FEAT_FAMINMAX arm.FEAT_CPA arm.FEAT_CPA2 arm.FEAT_ECV arm.FEAT_AFP "
        + "arm.FEAT_LSE2 arm.FEAT_CSV2 arm.FEAT_CSV3 arm.FEAT_DIT arm.AdvSIMD "
        + "arm.AdvSIMD_HPFPCvt arm.FEAT_FP16 arm.FEAT_SSBS arm.FEAT_BTI arm.FEAT_SME "
        + "arm.FEAT_SME2 arm.FEAT_SME2p1 arm.FEAT_MTE arm.FEAT_MTE2 arm.FEAT_MTE3 arm.FEAT_MTE4 "
        + "arm.FEAT_FPMR arm.FP_SyncExceptions floatingpoint neon neon_hpfp neon_fp16 "
        + "armv8_crc32 armv8_1_atomics armv8_2_fhm armv8_2_sha512 armv8_2_sha3 "
        + "armv8_3_compnum arm64")
        .split(separator: " ").map { "hw.optional.\($0)" }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    /// An integer sysctl, whether the kernel keeps it as 32 or 64 bits.
    static func int(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int64(Int32(truncatingIfNeeded: value)) : value
    }
}
