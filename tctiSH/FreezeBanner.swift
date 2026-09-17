//
//  FreezeBanner.swift
//  A banner that owns the screen while the app is unable to respond.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// A full-screen notice that dims everything behind it.
///
/// The spinner intentionally keeps turning throughout as its animation is
/// committed to the render server, and the render server is a different process
/// from the one the debugger has stopped.
///
/// `raiseAndWait` is the contract for a caller that is about to cause a freeze.
/// It does not return until the banner has actually been drawn to ensure that
/// it is actually visible.
final class FreezeBanner: UIView {

    /// How long a raise waits before actually appearing.
    ///
    /// Anything resolved faster than this never needed a banner, and would only
    /// have produced a flicker.
    private static let appearanceDelay: TimeInterval = 0.15

    /// How long `raiseAndWait` will wait for a frame before giving up.
    ///
    /// A backstop, not a timeout anyone should hit. Whatever the UI is doing,
    /// it is not worth holding up the boot indefinitely for.
    private static let drawDeadline: TimeInterval = 2

    /// The banner on screen, if there is one. Main thread only.
    private static var current: FreezeBanner?

    /// A raise that hasn't appeared yet, so `lower()` can call it off.
    private static var pendingRaise: DispatchWorkItem?

    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    // MARK: - Raising and lowering

    /// Puts the banner up, after `appearanceDelay`. Safe from any thread.
    static func raise(_ message: String) {
        onMain {
            if let current {
                current.message = message
                return
            }

            pendingRaise?.cancel()

            let raise = DispatchWorkItem { present(message) }
            pendingRaise = raise
            DispatchQueue.main.asyncAfter(deadline: .now() + appearanceDelay, execute: raise)
        }
    }

    /// Puts the banner up and blocks until it has been drawn.
    ///
    /// Call from the thread that is about to freeze the process, and never from
    /// the main thread: this waits on the main queue and would deadlock.
    static func raiseAndWait(_ message: String) {
        let drawn = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            pendingRaise?.cancel()
            pendingRaise = nil

            // Opaque at once. A fade would still be running when the process stops, and the caller
            // is about to stop it.
            present(message, fading: false)
            current?.superview?.layoutIfNeeded()

            // Hands this turn's layer changes to the render server *now*.
            //
            // The heart of the thing: UIKit commits once per run loop turn, and the caller traps
            // the moment this returns which is well inside the same turn. Ending an explicit
            // transaction group is not enough, because that group nests inside the run loop's own
            // and it is the outer one that reaches the render server.
            CATransaction.flush()
            drawn.signal()
        }

        if drawn.wait(timeout: .now() + drawDeadline) == .timedOut {
            Log.ui.warn("freeze banner: no frame within \(Int(drawDeadline))s; carrying on")
        }
    }

    /// Takes the banner down, and calls off one that hasn't appeared yet. Safe
    /// from any thread.
    static func lower() {
        onMain {
            pendingRaise?.cancel()
            pendingRaise = nil

            guard let banner = current else { return }
            current = nil

            UIView.animate(
                withDuration: 0.2,
                animations: { banner.alpha = 0 },
                completion: { _ in banner.removeFromSuperview() })
        }
    }

    /// Runs `body` on the main queue, without a hop if it is already there.
    private static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    /// Adds the banner to whatever is on screen. Main thread only.
    private static func present(_ message: String, fading: Bool = true) {
        pendingRaise = nil

        if let current {
            current.message = message
            return
        }

        guard let host = ViewController.getCurrent()?.view else {
            Log.ui.warn("freeze banner: nothing on screen to put it over")
            return
        }

        let banner = FreezeBanner(frame: host.bounds)
        banner.message = message
        banner.alpha = fading ? 0 : 1

        host.addSubview(banner)
        current = banner

        guard fading else { return }

        UIView.animate(withDuration: 0.15) { banner.alpha = 1 }
    }

    // MARK: - The view

    var message: String {
        get { label.text ?? "" }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = UIColor.black.withAlphaComponent(0.55)

        // Swallows every touch, which is the honest thing to do: the app is about to stop answering
        // them anyway.
        isUserInteractionEnabled = true
        accessibilityViewIsModal = true

        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0

        spinner.color = .label
        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),

            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(
                equalTo: card.contentView.trailingAnchor, constant: -28),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("FreezeBanner is not loaded from a nib")
    }
}
