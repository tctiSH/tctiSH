//
//  StatusPresenter.swift
//  Shows system status as a stack of floating pills.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// Owns the stack of status pills in the top right.
///
/// One pill per thing with something to say, stacked in the order they arrived.
/// They coexist rather than taking turns.
///
/// Items are addressed by key. Presenting the same key again updates that pill
/// in place, so a source that reports repeatedly, like a download, edits its
/// own pill instead of adding more.
///
/// Main thread only. Everything here is UI.
final class StatusPresenter {

    /// Something worth putting in front of the user.
    struct Item {

        /// Identifies the pill. Presenting the same key again updates it.
        var key: String

        var message: String
        var state: StatusPill.State

        /// How long to keep it, or nil to keep it until it's dismissed.
        var duration: TimeInterval?

        /// Colour of the message and the dial. Nil leaves it as it comes.
        var tint: UIColor?

        /// What tapping it does, if anything.
        var onTap: (() -> Void)?
    }

    private weak var parent: UIView?
    private let backdrop: UIColor

    /// The pills on screen, top to bottom, in the order they were added.
    private var pills: [(key: String, pill: StatusPill)] = []

    /// Pending auto-dismissals, by key.
    private var expiries: [String: DispatchWorkItem] = [:]

    init(over parent: UIView, backdrop: UIColor) {
        self.parent = parent
        self.backdrop = backdrop
    }

    /// Adds a pill, or updates the one already under this key.
    func present(_ item: Item) {
        expiries.removeValue(forKey: item.key)?.cancel()

        if let existing = pills.first(where: { $0.key == item.key })?.pill {
            existing.title = item.message
            existing.setState(item.state)
            existing.tint = item.tint ?? .label
            existing.onTap = item.onTap
        } else {
            guard let parent else { return }

            let pill = StatusPill.show(
                in: parent,
                title: item.message,
                over: backdrop,
                topOffset: offset(forRow: pills.count))
            pill.setState(item.state, animated: false)
            pill.tint = item.tint ?? .label
            pill.onTap = item.onTap

            // The pill animates itself off; this is just the bookkeeping, so
            // the stack closes up and any pending expiry is cancelled.
            let key = item.key
            pill.onSwipeAway = { [weak self] in self?.forget(key: key) }

            pills.append((key: item.key, pill: pill))
        }

        guard let duration = item.duration else { return }

        let expiry = DispatchWorkItem { [weak self] in self?.dismiss(key: item.key) }
        expiries[item.key] = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: expiry)
    }

    /// Takes one pill away, and closes the gap it leaves.
    func dismiss(key: String) {
        guard let index = pills.firstIndex(where: { $0.key == key }) else {
            expiries.removeValue(forKey: key)?.cancel()
            return
        }

        pills[index].pill.dismiss()
        forget(key: key)
    }

    /// Drops a pill from the stack without animating it away.
    ///
    /// For a pill that is already leaving under its own steam -- swiped, say --
    /// where dismissing it again would interrupt the animation it is in.
    private func forget(key: String) {
        expiries.removeValue(forKey: key)?.cancel()

        guard let index = pills.firstIndex(where: { $0.key == key }) else { return }

        pills.remove(at: index)
        restack()
    }

    /// Takes them all away.
    func clear() {
        for expiry in expiries.values { expiry.cancel() }
        expiries.removeAll()

        for entry in pills { entry.pill.dismiss() }
        pills.removeAll()
    }

    // MARK: - Layout

    /// Where the nth pill sits, measured from the top of the safe area.
    private func offset(forRow row: Int) -> CGFloat {
        StatusPill.topMargin
            + CGFloat(row) * (StatusPill.preferredHeight + StatusPill.stackSpacing)
    }

    /// Slides the survivors up into the gap.
    private func restack() {
        guard let parent, !pills.isEmpty else { return }

        for (row, entry) in pills.enumerated() {
            entry.pill.topConstraint.constant = offset(forRow: row)
        }

        UIView.animate(
            withDuration: 0.25, delay: 0,
            usingSpringWithDamping: 0.85, initialSpringVelocity: 0
        ) {
            parent.layoutIfNeeded()
        }
    }
}
