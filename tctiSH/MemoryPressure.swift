//
//  MemoryPressure.swift
//  How much room the system thinks it has.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import UIKit

/// What the OS is saying about memory usage.
///
/// A dispatch source distinguishes warning from critical and says when the
/// pressure has passed, while UIKit's memory warning says none of that, but it
/// is the signal an app is actually always handed. It arrives on device under
/// real pressure, and it is the only one of the two that can be provoked in a
/// simulator.
enum MemoryPressure {

    enum Level: Int, Comparable {
        case normal = 0
        case warning = 1
        case critical = 2

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var description: String {
            switch self {
            case .normal: return "normal"
            case .warning: return "warning"
            case .critical: return "critical"
            }
        }
    }

    /// What the system is saying, taking every source at its worst.
    static var current: Level {
        var level = sourceLevel

        if let until = warningUntil, until > Date() {
            level = max(level, .warning)
        }

        return level
    }

    /// Posted on the main queue whenever something might have changed.
    static let didChange = Notification.Name("io.ara.tctish.memoryPressureDidChange")

    // MARK: - The sources

    /// What the dispatch source last said. The only one that can say "better".
    private static var sourceLevel: Level = .normal

    /// When a UIKit memory warning stops counting.
    ///
    /// A warning is a moment rather than a state so it is given a life rather
    /// than being left to hold the level up for ever. If the pressure is real
    /// the dispatch source will be saying so as well, and that has no expiry.
    private static var warningUntil: Date?

    /// How long a UIKit warning counts for.
    private static let warningLingersFor: TimeInterval = 30

    private static var source: DispatchSourceMemoryPressure?

    /// Starts listening. Safe to call more than once.
    static func start() {
        guard source == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)

        source.setEventHandler {
            let data = source.data
            let level: Level =
                data.contains(.critical)
                ? .critical : (data.contains(.warning) ? .warning : .normal)

            guard level != sourceLevel else { return }

            Log.ui.note("memory pressure: system says \(level.description)")
            sourceLevel = level
            announce()
        }

        source.resume()
        Self.source = source

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Log.ui.note("memory pressure: UIKit sent a memory warning")
            warningUntil = Date().addingTimeInterval(warningLingersFor)
            announce()
        }
    }

    private static func announce() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
