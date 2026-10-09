//
//  KeyBar.swift
//  The keys a terminal needs that the software keyboard doesn't have.
//
//  Copyright © 2026 Ara Adkins.
//

import GameController
import SwiftTerm
import UIKit

// MARK: - The bar

/// The bar that floats above the software keyboard.
///
/// Conventionally this is laid out as two capsules, one containing the user's
/// pinned keys and more on the left, and one containing system actions on the
/// right. It is the input accessory for the terminal.
///
/// When the two capsules get close together they instead merge into a single,
/// centered one, with pinned keys that do not fit being left off, starting with
/// the last pinned key.
///
/// On a phone in landscape, where height is scarce, the bar instead becomes
/// two vertical rails either side of the terminal; see `placeRails(in:)`.
final class KeyBar: UIView, UIInputViewAudioFeedback {

    // MARK: Sizes

    private static let buttonWidth: CGFloat = 44
    private static let capsuleHeight: CGFloat = 44

    /// Inside each capsule, either side of its buttons.
    private static let capsuleInset: CGFloat = 4

    /// Between the capsules and the edges of the screen.
    private static let margin: CGFloat = 8

    /// Above and below the capsules.
    private static let verticalMargin: CGFloat = 6

    /// The narrowest the space between the two capsules may get before they
    /// merge into one.
    private static let mergeGap: CGFloat = 24

    /// The trailing capsule's buttons: Hide Keyboard, for now.
    private static let trailingButtons = 1

    /// The trailing capsule: one button, so a circle.
    private static var trailingWidth: CGFloat { capsuleHeight }

    /// The bar's height, less any safe area beneath it.
    static var height: CGFloat { capsuleHeight + verticalMargin * 2 }

    /// The width each rail takes from the edge of the safe area.
    static var railWidth: CGFloat { margin + capsuleHeight }

    private static func capsuleWidth(buttons: Int) -> CGFloat {
        CGFloat(buttons) * buttonWidth + capsuleInset * 2
    }

    /// How many pinned keys fit beside More with the capsules apart, in a bar
    /// this wide.
    private static func separateCapacity(forWidth width: CGFloat) -> Int {
        let available = width - margin * 2 - mergeGap - trailingWidth - capsuleInset * 2
        return max(0, Int(available / buttonWidth) - 1)
    }

    /// How many pinned keys fit in a bar this wide: with the capsules merged,
    /// which is the most there can be, as merged is how a full bar is laid out.
    static func capacity(forWidth width: CGFloat) -> Int {
        let available = width - margin * 2 - capsuleInset * 2
        return max(0, Int(available / buttonWidth) - 1 - trailingButtons)
    }

    // MARK: State

    private weak var terminal: TctiTermView?
    private let openSettings: () -> Void

    private let leading = KeyBar.makeCapsule()
    private let trailing = KeyBar.makeCapsule()

    /// The left rail's capsule, holding pinned keys.
    private let leftRail = KeyBar.makeCapsule()

    private let more = MoreButton(configuration: .plain())
    private let dismiss = UIButton(configuration: .plain())

    /// What's saved, whether or not it all fits.
    private var pinned = BarKey.pinned

    /// What's on the bar now, and the buttons showing it.
    private var shown: [BarKey] = []
    private var pinnedViews: [UIView] = []

    /// The modifier buttons, if pinned, to light up while they're on.
    private var modifierButtons: [BarKey: UIButton] = [:]

    /// Tab, if pinned, to turn round while Shift is on.
    private var tabButton: UIButton?

    /// Whether Tab is showing Shift-Tab.
    private var tabIsShifted = false

    /// The modifiers a held arrow was pressed with, kept for as long as it
    /// repeats; nil when no arrow is held.
    private var heldArrowModifiers: KeyModifiers?

    /// Watches the software keyboard's Shift, which says nothing when it
    /// changes; see `SoftKeyboard`. Only while the bar is on screen.
    private var shiftWatch: Timer?

    /// What More's menu was last built to show, so that it's built again only
    /// when that changes: it's a good many items, and the bar's keys, and an
    /// arrow repeating, would otherwise rebuild it every time.
    private var builtMenu: MenuState?

    private struct MenuState: Equatable {
        var shown: [BarKey]
        var tabIsShifted: Bool
        var armed: [Bool]
    }

    /// More's character icons, drawn once each.
    private static var characterIcons: [BarKey: UIImage] = [:]

    private var hidesWithHardwareKeyboard = AppSetting.hideKeyBarWithHardwareKeyboard.bool

    /// The view the rails are drawn in. It covers the app's view and passes
    /// through any touch that misses a capsule. The installer adds it, as the
    /// bar itself lives in the keyboard's window.
    let rails: UIView = RailsView()

    /// Whether the bar is shown as rails. Set by the view controller, which
    /// knows the orientation even while the keyboard, and so the bar, is off
    /// screen. Applies with a hardware keyboard too.
    var usesRails = false {
        didSet {
            guard usesRails != oldValue else { return }
            updateMode()
        }
    }

    /// Whether the rails are shown or fading in.
    private var railsShown = false

    /// Holds the rails' capsules. From iOS 26 it's a glass container, so
    /// capsules blend as they meet and separate.
    private let railGlass: UIVisualEffectView = {
        if #available(iOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassContainerEffect())
        }
        return UIVisualEffectView(effect: nil)
    }()

    /// Whether the rails should next appear by flowing out of the keyboard,
    /// rather than fading in. Set when the bar became rails while the strip
    /// was off screen.
    private var morphsIn = false

    private struct StripLayout {
        var keys: [BarKey: CGRect]
        var more: CGRect
        var dismiss: CGRect

        /// Hide Keyboard's own capsule, if it had one.
        var dismissCapsule: CGRect?
    }

    /// Whether Hide Keyboard is moving in its own capsule to the top of the
    /// right rail, joining it on arrival.
    private var dismissArriving = false

    /// Whether the rails are animating into place. Layout changes meanwhile
    /// retarget the animation rather than cutting it short.
    private var morphing = false

    /// Whether the rails are flowing back into the strip as the phone turns
    /// to portrait; see `beginReturningToStrip`.
    private var returning = false

    /// The number of pinned keys on the left rail.
    private var leftSlots = 0

    /// The spring the rails flow with.
    private static let morphDuration: TimeInterval = 0.6
    private static let morphDamping: CGFloat = 0.78

    /// How many pinned keys the rails last held between them, or nil if they
    /// haven't been shown; it depends on the keyboard's height.
    private(set) static var railCapacity: Int?

    /// Whether More's menu is open.
    var isMenuOpen: Bool { more.isMenuOpen }

    /// Closes More's menu, as a hardware keyboard's Esc does.
    func closeMenu() {
        more.contextMenuInteraction?.dismissMenu()
    }

    /// Where the capsules are drawn, in the bar's coordinates. Everything else
    /// is see-through.
    var capsuleFrames: [CGRect] {
        [leading, trailing].filter { $0.superview === self && !$0.isHidden }.map(\.frame)
    }

    /// Called whenever the bar may have moved on screen, or come or gone.
    var didMove: (() -> Void)?

    /// Where the bar is on screen, in screen coordinates, or nil while it isn't
    /// on one.
    var screenFrame: CGRect? {
        guard let window, let screen = window.windowScene?.screen else { return nil }
        return convert(bounds, to: screen.coordinateSpace)
    }

    // MARK: Setup

    /// Puts a bar on `terminal`, in place of SwiftTerm's.
    ///
    /// Held by whoever calls this: while a hardware keyboard has it hidden, the
    /// terminal lets go of it.
    static func install(on terminal: TctiTermView, openSettings: @escaping () -> Void) -> KeyBar {
        let bar = KeyBar(terminal: terminal, openSettings: openSettings)
        bar.updateAttachment()
        return bar
    }

    private init(terminal: TctiTermView, openSettings: @escaping () -> Void) {
        self.terminal = terminal
        self.openSettings = openSettings

        super.init(frame: CGRect(x: 0, y: 0, width: terminal.bounds.width, height: Self.height))

        autoresizingMask = .flexibleHeight
        backgroundColor = .clear

        // It floats over the terminal rather than the system's chrome, and the terminal is dark.
        overrideUserInterfaceStyle = .dark

        // The keyboard's window, which the bar is in, doesn't take the app's tint, so the bar takes
        // the accent itself; the lit modifiers, the pad's arrows and the hovers all follow it.
        tintColor = Accent.custom

        addSubview(leading)
        addSubview(trailing)

        Self.style(more, symbol: "ellipsis", label: "More Keys")
        more.showsMenuAsPrimaryAction = true

        // Whichever way the menu opens, its first item is the one nearest the finger that opened
        // it. Settings goes first so that it's always the closest.
        more.preferredMenuElementOrder = .priority
        leading.contentView.addSubview(more)

        // From a rail, the menu opens in the app's window and would take focus from the terminal.
        // iOS hides the keyboard regardless, but as the terminal keeps focus, it returns once the
        // menu closes.
        more.menuWillOpen = { [weak self] in
            guard let self, usesRails else { return }
            self.terminal?.holdsKeyboard = true
        }
        more.menuWillClose = { [weak self] in self?.terminal?.holdsKeyboard = false }

        Self.style(dismiss, symbol: "keyboard.chevron.compact.down", label: "Hide Keyboard")
        dismiss.addAction(
            UIAction { [weak self] _ in
                // An explicit request to hide, so it overrides any hold.
                self?.terminal?.holdsKeyboard = false
                _ = self?.terminal?.resignFirstResponder()
            },
            for: .touchUpInside)

        trailing.contentView.addSubview(dismiss)

        // Styled as the bar is, since the capsules inherit from their container.
        rails.backgroundColor = .clear
        rails.overrideUserInterfaceStyle = .dark
        rails.tintColor = Accent.custom
        rails.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        rails.alpha = 0
        rails.isHidden = true
        rails.addSubview(railGlass)
        railGlass.contentView.addSubview(leftRail)
        (rails as? RailsView)?.capsules = [leading, trailing, leftRail]

        observe()
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this bar is built in code")
    }

    /// A capsule of glass, or of frosted material before iOS 26.
    private static func makeCapsule() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let capsule = UIVisualEffectView(effect: UIGlassEffect())
            capsule.cornerConfiguration = .capsule()
            return capsule
        }

        let capsule = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        capsule.layer.cornerCurve = .continuous
        capsule.clipsToBounds = true
        return capsule
    }

    private static func style(_ button: UIButton, symbol: String, label: String) {
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.baseForegroundColor = .label
        button.accessibilityLabel = label
        hover(button)
    }

    /// How far the pointer's highlight sits inside a button's slot.
    private static let hoverInset: CGFloat = 4

    /// The same highlight under the pointer for everything on the bar: a circle
    /// inside the button's slot, as the capsules are rounded. Left to UIKit,
    /// each button's is shaped to whatever it shows, so an icon, a label and
    /// the arrow pad each get a different one.
    fileprivate static func hoverStyle(for view: UIView) -> UIPointerStyle {
        let rect = view.frame.insetBy(dx: hoverInset, dy: hoverInset)
        let side = min(rect.width, rect.height)
        let circle = CGRect(
            x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        return UIPointerStyle(
            effect: .highlight(UITargetedPreview(view: view)),
            shape: .roundedRect(circle, radius: side / 2))
    }

    fileprivate static func hover(_ button: UIButton) {
        button.isPointerInteractionEnabled = true
        button.pointerStyleProvider = { button, _, _ in hoverStyle(for: button) }
    }

    // MARK: Sizing

    override func didMoveToWindow() {
        super.didMoveToWindow()
        didMove?()
        watchSoftShift()
    }

    /// Watches the software keyboard's Shift while the bar is on screen and the
    /// app in front, and not otherwise: it says nothing when it changes, so it
    /// has to be looked at, and there's no call to look while nobody can see
    /// the bar.
    private func watchSoftShift() {
        shiftWatch?.invalidate()
        shiftWatch = nil
        guard window != nil, UIApplication.shared.applicationState != .background else { return }

        let watch = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshTab()
        }
        RunLoop.main.add(watch, forMode: .common)
        shiftWatch = watch
    }

    /// How much of the safe area beneath the bar it keeps clear of.
    ///
    /// On iPhone, all of it: along the bottom of the screen, when a hardware
    /// keyboard stands in for the software one, the screen's well-rounded
    /// corners otherwise cut the capsules off. On iPad, none: its corners are
    /// tight enough that a capsule's rounding nests into them, which is where
    /// it looks right, over the home indicator's strip.
    private var bottomInset: CGFloat {
        traitCollection.userInterfaceIdiom == .phone ? safeAreaInsets.bottom : 0
    }

    /// Taller by any safe area beneath it that the bar keeps clear of. Zero
    /// height as rails, unless they're returning to the strip.
    override var intrinsicContentSize: CGSize {
        let height = usesRails && !returning ? 0 : Self.height + bottomInset
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // The view controller lays out the rails, as it knows where the terminal is.
        guard !usesRails else {
            didMove?()
            return
        }

        let content = bounds.inset(
            by: UIEdgeInsets(
                top: Self.verticalMargin, left: safeAreaInsets.left + Self.margin,
                bottom: Self.verticalMargin + bottomInset,
                right: safeAreaInsets.right + Self.margin))

        // Fitting is decided here, as only now is the width known; rotating, or iPad's floating
        // keyboard, changes it.
        let width = content.width + Self.margin * 2
        let wanted = Array(pinned.prefix(Self.capacity(forWidth: width)))
        if wanted != shown {
            shown = wanted
            rebuildPinned()
        }

        // Apart while there's comfortable room between them; merged into one, centered, once there
        // isn't, rather than two capsules all but touching.
        let merged = shown.count > Self.separateCapacity(forWidth: width)
        let places = Self.stripPlaces(pins: shown.count, merged: merged, in: content)
        trailing.isHidden = merged

        leading.frame = places.leading
        var buttons = pinnedViews + [more]
        var buttonPlaces = places.pins + [places.more]
        if let capsule = places.trailing {
            trailing.frame = capsule
            trailing.contentView.addSubview(dismiss)
            dismiss.frame = trailing.bounds
        } else {
            buttons.append(dismiss)
            buttonPlaces.append(places.dismiss)
        }
        for (button, place) in zip(buttons, buttonPlaces) {
            leading.contentView.addSubview(button)
            button.frame = place.offsetBy(dx: -places.leading.minX, dy: -places.leading.minY)
        }

        more.sideways = nil
        roundCapsules()
        didMove?()
    }

    /// The strip's capsule and key frames within `content`. Pinned keys and
    /// More share a capsule at the leading edge, and Hide Keyboard has its own
    /// at the trailing edge. Merged, all of them share one centered capsule.
    private struct StripPlaces {
        var pins: [CGRect]
        var more: CGRect
        var dismiss: CGRect
        var leading: CGRect
        var trailing: CGRect?
    }

    private static func stripPlaces(pins count: Int, merged: Bool, in content: CGRect)
        -> StripPlaces
    {
        func slot(_ index: Int, from x: CGFloat) -> CGRect {
            CGRect(
                x: x + capsuleInset + CGFloat(index) * buttonWidth, y: content.minY,
                width: buttonWidth, height: capsuleHeight)
        }

        if merged {
            let width = capsuleWidth(buttons: count + 2)
            let x = content.midX - width / 2
            return StripPlaces(
                pins: (0..<count).map { slot($0, from: x) }, more: slot(count, from: x),
                dismiss: slot(count + 1, from: x),
                leading: CGRect(x: x, y: content.minY, width: width, height: capsuleHeight),
                trailing: nil)
        }

        let trailing = CGRect(
            x: content.maxX - trailingWidth, y: content.minY, width: trailingWidth,
            height: capsuleHeight)
        return StripPlaces(
            pins: (0..<count).map { slot($0, from: content.minX) },
            more: slot(count, from: content.minX), dismiss: trailing,
            leading: CGRect(
                x: content.minX, y: content.minY, width: capsuleWidth(buttons: count + 1),
                height: capsuleHeight),
            trailing: trailing)
    }

    /// Lines buttons up in a capsule, across it or down it, adding each to it,
    /// since buttons move between capsules. Starts `from` slots in.
    private func lay(
        out views: [UIView], in capsule: UIVisualEffectView, down: Bool = false, from: Int = 0
    ) {
        for (index, view) in views.enumerated() {
            capsule.contentView.addSubview(view)
            let offset = Self.capsuleInset + CGFloat(from + index) * Self.buttonWidth
            view.frame =
                down
                ? CGRect(x: 0, y: offset, width: Self.capsuleHeight, height: Self.buttonWidth)
                : CGRect(x: offset, y: 0, width: Self.buttonWidth, height: Self.capsuleHeight)
        }
    }

    /// Rounds the capsules before iOS 26, which does it itself.
    private func roundCapsules() {
        if #unavailable(iOS 26.0) {
            for capsule in [leading, trailing, leftRail] {
                capsule.layer.cornerRadius = Self.capsuleHeight / 2
            }
        }
    }

    // MARK: Rails

    /// Lays out the rails either side of `area`, in the app's view, or hides
    /// them given nil. `area` spans the safe area's width, from its top down to
    /// the keyboard, or to the screen's bottom with a hardware keyboard.
    ///
    /// The left rail holds the pinned keys in order. The right rail holds Hide
    /// Keyboard, More, then any pins that didn't fit on the left. Both share
    /// the bottom edge a full rail would have if centered in `area`.
    func placeRails(in area: CGRect?) {
        // Returning to the strip; see `flowIntoStrip`.
        guard !returning else { return }

        guard usesRails, let area else {
            showRails(false)
            return
        }

        let slots = Self.railSlots(forHeight: area.height)
        let bottom = min(
            area.maxY - (area.height - Self.capsuleWidth(buttons: slots)) / 2, railsFloor)
        let (left, right) = prepareRails(slots: slots)
        let leftX = area.minX + Self.margin
        let rightX = area.maxX - Self.margin - Self.capsuleHeight

        let stack = [dismiss] + right
        leftRail.isHidden = left.isEmpty

        if morphsIn, !railsShown {
            morphsIn = false
            startMorphOnKeyboard(left: left, right: stack, in: area)
        }
        trailing.isHidden = !dismissArriving

        let lengths = (
            Self.capsuleWidth(buttons: left.count), Self.capsuleWidth(buttons: stack.count)
        )
        let rightFrame = CGRect(
            x: rightX, y: bottom - lengths.1, width: Self.capsuleHeight, height: lengths.1)
        animating(gliding: railsShown) {
            self.leftRail.frame = CGRect(
                x: leftX, y: bottom - lengths.0, width: Self.capsuleHeight, height: lengths.0)
            self.lay(out: left, in: self.leftRail, down: true)

            self.leading.frame = rightFrame
            if self.dismissArriving {
                // Hide Keyboard's capsule moves to the top of the rail.
                self.lay(out: right, in: self.leading, down: true, from: 1)
                self.trailing.frame = CGRect(
                    origin: rightFrame.origin,
                    size: CGSize(width: Self.capsuleHeight, height: Self.capsuleHeight))
                self.dismiss.frame = self.trailing.bounds
            } else {
                self.lay(out: stack, in: self.leading, down: true)
            }
        }

        more.sideways = (restingBottom(in: area), rails)
        roundCapsules()
        showRails(true)
    }

    /// The number of keys that fit in a rail of this height.
    private static func railSlots(forHeight height: CGFloat) -> Int {
        let room = height - margin * 2 - capsuleInset * 2
        return max(0, Int(room / buttonWidth))
    }

    /// Shows as many pinned keys as fit: `slots` on the left, and two fewer on
    /// the right, which also holds Hide Keyboard and More. Returns the left
    /// rail's keys, and More followed by the right rail's pins.
    private func prepareRails(slots: Int) -> (left: [UIView], right: [UIView]) {
        let rightCapacity = max(0, slots - 2)
        Self.railCapacity = slots + rightCapacity
        leftSlots = slots

        let wanted = Array(pinned.prefix(slots + rightCapacity))
        if wanted != shown {
            shown = wanted
            rebuildPinned()
        }
        return (Array(pinnedViews.prefix(slots)), [more] + pinnedViews.dropFirst(slots))
    }

    // MARK: Flowing between strip and rails

    /// Becomes rails as the phone turns to landscape, starting from the
    /// strip's current position so the capsules turn with the screen.
    /// `height` is the expected rail height; the rails are laid out again as
    /// the screen turns, and once the keyboard reports its position.
    func turnIntoRails(height: CGFloat) {
        guard !usesRails else { return }

        // Captured before anything moves.
        let strip = stripLayout()
        usesRails = true
        guard let strip, let screen = rails.window?.windowScene?.screen else { return }

        morphsIn = false
        let slots = Self.railSlots(forHeight: height)
        let (left, right) = prepareRails(slots: slots)
        let leftKeys = Array(shown.prefix(slots))

        let here = { (frame: CGRect) in self.rails.convert(frame, from: screen.coordinateSpace) }
        let leftPlaces = leftKeys.map { strip.keys[$0].map(here) }
        let rightPlaces =
            [here(strip.more)] + shown.dropFirst(slots).map { strip.keys[$0].map(here) }

        UIView.performWithoutAnimation {
            leftRail.isHidden = left.isEmpty
            gather(left, at: leftPlaces, in: leftRail)

            if let capsule = strip.dismissCapsule {
                gather(right, at: rightPlaces, in: leading)
                trailing.isHidden = false
                trailing.frame = here(capsule)
                trailing.contentView.addSubview(dismiss)
                dismiss.frame = trailing.bounds
                dismissArriving = true
            } else {
                gather([dismiss] + right, at: [here(strip.dismiss)] + rightPlaces, in: leading)
            }
            roundCapsules()
        }

        morphing = true
        showRails(true)
    }

    /// Begins returning to the strip as the phone turns to portrait. The bar
    /// regains its height on the keyboard, while the capsules stay in the
    /// rails' view to flow there; see `flowIntoStrip`. Does nothing unless the
    /// rails are shown.
    func beginReturningToStrip() {
        guard usesRails, railsShown else { return }
        returning = true
        invalidateIntrinsicContentSize()
    }

    /// Moves each key to its place on the strip, alongside the turn to
    /// portrait, for a bar whose top is expected at `barTop` on a screen
    /// `width` wide. If the strip keeps Hide Keyboard apart, it splits off in
    /// its own capsule. Once the turn ends, the strip takes the keys back in
    /// the same places.
    func flowIntoStrip(barTop: CGFloat, width: CGFloat) {
        guard returning else { return }

        let content = CGRect(
            x: Self.margin, y: barTop + Self.verticalMargin, width: width - Self.margin * 2,
            height: Self.capsuleHeight)
        let count = min(pinned.count, Self.capacity(forWidth: width))
        let merged = count > Self.separateCapacity(forWidth: width)
        let places = Self.stripPlaces(pins: count, merged: merged, in: content)

        // A key without room on the strip goes to More's place.
        func pinPlace(_ index: Int) -> CGRect {
            index < places.pins.count ? places.pins[index] : places.more
        }

        let left = Array(pinnedViews.prefix(leftSlots))
        let overflow = Array(pinnedViews.dropFirst(leftSlots))

        if !merged {
            UIView.performWithoutAnimation {
                trailing.frame = railGlass.contentView.convert(
                    dismiss.frame, from: dismiss.superview)
                trailing.contentView.addSubview(dismiss)
                dismiss.frame = trailing.bounds
                trailing.isHidden = false
            }
        }

        gather(left, at: left.indices.map(pinPlace), in: leftRail)

        var right: [UIView] = overflow + [more]
        var rightPlaces = overflow.indices.map { pinPlace(leftSlots + $0) } + [places.more]
        if merged {
            right.append(dismiss)
            rightPlaces.append(places.dismiss)
        }
        gather(right, at: rightPlaces, in: leading)

        if let capsule = places.trailing {
            trailing.frame = capsule
            dismiss.frame = trailing.bounds
        }
    }

    /// Sizes a capsule to enclose its keys' places, and moves them there. A key
    /// with no place goes at the capsule's end.
    private func gather(_ views: [UIView], at places: [CGRect?], in capsule: UIVisualEffectView) {
        let known = places.compactMap { $0 }
        guard let first = known.first else { return }

        capsule.frame = known.reduce(first) { $0.union($1) }
            .insetBy(dx: -Self.capsuleInset, dy: 0)
        for (view, place) in zip(views, places) {
            capsule.contentView.addSubview(view)
            let start =
                place
                ?? CGRect(
                    x: capsule.frame.maxX - Self.capsuleInset - Self.buttonWidth,
                    y: capsule.frame.minY, width: Self.buttonWidth, height: Self.capsuleHeight)
            view.frame = start.offsetBy(dx: -capsule.frame.minX, dy: -capsule.frame.minY)
        }
    }

    /// Where the rails start when there was no strip on screen to flow from:
    /// end to end along the keyboard's top edge. The right rail's keys are
    /// reversed, so Hide Keyboard rises to its top.
    private func startMorphOnKeyboard(left: [UIView], right: [UIView], in area: CGRect) {
        let leftWidth = Self.capsuleWidth(buttons: left.count)
        let rightWidth = Self.capsuleWidth(buttons: right.count)
        let start = area.midX - (leftWidth + rightWidth) / 2
        let y = area.maxY - Self.verticalMargin - Self.capsuleHeight

        UIView.performWithoutAnimation {
            leftRail.frame = CGRect(x: start, y: y, width: leftWidth, height: Self.capsuleHeight)
            lay(out: left, in: leftRail)
            leading.frame = CGRect(
                x: start + leftWidth, y: y, width: rightWidth, height: Self.capsuleHeight)
            lay(out: right.reversed(), in: leading)
        }
        morphing = true
    }

    /// Applies a rails layout change: springing if the rails are flowing into
    /// place, gliding if they're already shown (as when the keyboard isn't
    /// where it was expected), and otherwise at once.
    private func animating(gliding: Bool, _ changes: @escaping () -> Void) {
        guard morphing || gliding else {
            changes()
            return
        }

        UIView.animate(
            withDuration: Self.morphDuration, delay: 0,
            usingSpringWithDamping: morphing ? Self.morphDamping : 1, initialSpringVelocity: 0,
            // Keeps this spring while the screen turns, rather than the turn's curve.
            options: [
                .beginFromCurrentState, .allowUserInteraction, .overrideInheritedDuration,
                .overrideInheritedCurve,
            ], animations: changes
        ) { [weak self] finished in
            guard let self, finished, morphing else { return }
            morphing = false

            // Hide Keyboard joins the rail where its capsule arrived.
            if dismissArriving {
                dismissArriving = false
                trailing.isHidden = true
                lay(out: [dismiss], in: leading, down: true)
            }
        }
    }

    /// The strip's key and capsule frames on screen, or nil if it's off screen.
    private func stripLayout() -> StripLayout? {
        guard let screen = window?.windowScene?.screen, !leading.isHidden else { return nil }

        func onScreen(_ view: UIView) -> CGRect {
            view.convert(view.bounds, to: screen.coordinateSpace)
        }
        return StripLayout(
            keys: Dictionary(uniqueKeysWithValues: zip(shown, pinnedViews.map(onScreen))),
            more: onScreen(more), dismiss: onScreen(dismiss),
            dismissCapsule: trailing.isHidden ? nil : onScreen(trailing))
    }

    /// The rails' bottom edge with the keyboard hidden, as it is under More's
    /// menu: centered on the space from the top of `area` to the screen's
    /// bottom.
    private func restingBottom(in area: CGRect) -> CGFloat {
        let height = rails.bounds.maxY - area.minY
        let slots = Self.railSlots(forHeight: height)
        return min(rails.bounds.maxY - (height - Self.capsuleWidth(buttons: slots)) / 2, railsFloor)
    }

    /// The lowest the rails go: above the home indicator, which More's menu
    /// keeps out of, so the menu and its capsule end level.
    private var railsFloor: CGFloat {
        rails.bounds.maxY - rails.safeAreaInsets.bottom
    }

    /// Fades the rails in or out with the keyboard.
    private func showRails(_ show: Bool) {
        guard show != railsShown else { return }
        railsShown = show

        if show {
            rails.isHidden = false
        }
        // Flowing from the strip, they replace what was on screen, so no fade.
        if show, morphing {
            rails.alpha = 1
            return
        }
        UIView.animate(withDuration: 0.2) {
            self.rails.alpha = show ? 1 : 0
        } completion: { _ in
            if !self.railsShown {
                self.rails.isHidden = true
            }
        }
    }

    /// Switches between rails and strip, moving the capsules to the view that
    /// now draws them.
    private func updateMode() {
        dismissArriving = false
        morphing = false

        let host = usesRails ? railGlass.contentView : self
        host.addSubview(leading)
        host.addSubview(trailing)

        // Rails that didn't flow from the strip flow from the keyboard when next shown.
        morphsIn = usesRails
        if !usesRails {
            // The strip shows the same keys in the same places, so hide the rails at once.
            returning = false
            railsShown = false
            rails.alpha = 0
            rails.isHidden = true
        }

        // Resize, which the keyboard follows, and lay out again.
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        didMove?()
    }

    // MARK: Building

    /// Starts again from what's saved. Layout then puts back as much as fits.
    private func rebuild() {
        pinned = BarKey.pinned
        shown = []
        rebuildPinned()
        setNeedsLayout()
        didMove?()
    }

    private func rebuildPinned() {
        pinnedViews.forEach { $0.removeFromSuperview() }
        modifierButtons = [:]
        tabButton = nil

        pinnedViews = shown.map { key in
            key == .arrows ? makeArrowPad() : makeButton(for: key)
        }
        pinnedViews.forEach { leading.contentView.addSubview($0) }

        refreshModifiers()
    }

    private func makeButton(for key: BarKey) -> UIButton {
        let button = UIButton(configuration: .plain())
        button.configuration?.baseForegroundColor = .label
        button.accessibilityLabel = key.name
        Self.hover(button)

        if let symbol = key.symbol {
            button.configuration?.image = UIImage(systemName: symbol)
        } else {
            var title = AttributedString(key.glyph)
            title.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            button.configuration?.attributedTitle = title
            button.configuration?.contentInsets = .zero
        }

        if key == .tab {
            tabButton = button
        }

        if key.modifier != nil {
            // Lit while on, as the hardware modifier keys of the iPad's keyboards are: as tinted
            // glass from iOS 26, as the system's selected buttons are, and as a tinted fill before.
            // Inset as the pointer's highlight is, so the two agree.
            let symbol = key.symbol.flatMap { UIImage(systemName: $0) }
            button.configurationUpdateHandler = { button in
                var configuration: UIButton.Configuration
                if button.isSelected, #available(iOS 26.0, *) {
                    configuration = .prominentGlass()
                    configuration.baseForegroundColor = Accent.foreground
                } else {
                    configuration = .plain()
                    configuration.baseForegroundColor = .label
                    if button.isSelected {
                        configuration.background.backgroundColor =
                            .tintColor.withAlphaComponent(0.4)
                    }
                }
                configuration.image = symbol
                configuration.cornerStyle = .capsule
                configuration.background.backgroundInsets = NSDirectionalEdgeInsets(
                    top: Self.hoverInset, leading: Self.hoverInset, bottom: Self.hoverInset,
                    trailing: Self.hoverInset)
                button.configuration = configuration
            }
            modifierButtons[key] = button
        }

        // Modifiers on touching down, as the keyboard's Shift does; keys that send something on
        // lifting, so a finger can slide off one to think better of it.
        button.addAction(
            UIAction { [weak self] _ in self?.press(key) },
            for: key.modifier != nil ? .touchDown : .touchUpInside)
        return button
    }

    private func makeArrowPad() -> ArrowPad {
        let pad = ArrowPad()
        pad.press = { [weak self] key, repeating in self?.pressArrow(key, repeating: repeating) }
        pad.release = { [weak self] in
            self?.heldArrowModifiers = nil
            self?.refreshModifiers()
        }
        return pad
    }

    /// More: Settings, then every key that isn't on the bar, by group.
    private func rebuildMenu() {
        let state = MenuState(
            shown: shown, tabIsShifted: tabIsShifted,
            armed: [BarKey.shift, .ctrl, .alt, .superKey].map(isOn))
        guard state != builtMenu else { return }
        builtMenu = state

        let settings = UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) {
            [weak self] _ in self?.openSettings()
        }

        var elements: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: [settings])
        ]

        let onBar = Set(shown)
        let offBar = BarKey.allCases.filter { key in
            if key == .arrows { return false }
            if key.isSingleArrow { return !onBar.contains(.arrows) }
            return !onBar.contains(key)
        }

        for group in BarKey.Group.allCases {
            let keys = offBar.filter { $0.group == group }
            guard !keys.isEmpty else { continue }

            var children: [UIMenuElement] = keys.map(menuAction(for:))
            if group == .function {
                // Made as the list opens, which is when how much room it has is known.
                children = [
                    UIDeferredMenuElement.uncached { [weak self] completion in
                        completion(self?.functionKeyItems(keys) ?? [])
                    }
                ]
            }

            // Copy is only offered with something to copy, which changes without the bar hearing of
            // it, so the clipboard's items are made as the menu opens.
            if group == .clipboard {
                children = [
                    UIDeferredMenuElement.uncached { [weak self] completion in
                        completion(keys.compactMap { self?.menuAction(for: $0) })
                    }
                ]
            }

            if group.isSubmenu {
                elements.append(
                    UIMenu(
                        title: group.title, image: UIImage(systemName: group.symbol),
                        children: children))
            } else {
                elements.append(UIMenu(options: .displayInline, children: children))
            }
        }

        more.menu = UIMenu(children: elements)
    }

    /// The height of a row in a menu, for judging whether a list will fit.
    private static let menuRowHeight: CGFloat = 44

    /// Function Keys: F1 to F12 as on any keyboard, with the extended ones in a
    /// submenu at the far end, as all 22 in one list run off the screen.
    ///
    /// More lays its items out from the finger outwards, so F1, which comes
    /// first, sits beside the finger or pointer that opened it. Where all
    /// twelve won't fit in the room above the bar, as on a phone, the list
    /// would scroll, and start at its top, the far end. So there, only the
    /// first eight are listed, and the rest of the twelve go into a separate
    /// submenu, between F8 and F13–F22: F9–F12. Should even that not fit, F1 to
    /// F4, with F5–F8 and F9–F12 as submenus.
    private func functionKeyItems(_ keys: [BarKey]) -> [UIMenuElement] {
        let common = keys.filter { ($0.functionNumber ?? 0) <= 12 }
        let extended = keys.filter { ($0.functionNumber ?? 0) > 12 }
        let room: CGFloat
        if let sideways = more.sideways {
            // From a rail, the menu can use the height down to the rails' resting bottom.
            room = sideways.bottom - sideways.space.safeAreaInsets.top
        } else {
            room = (screenFrame?.minY ?? 0) - (window?.safeAreaInsets.top ?? 0)
        }

        /// The keys listed as they are, and the rest in submenus of four.
        func split(listing count: Int) -> (listed: [BarKey], grouped: [[BarKey]]) {
            let listed = Array(common.prefix(count))
            let rest = Array(common.dropFirst(count))
            let grouped = stride(from: 0, to: rest.count, by: 4).map {
                Array(rest[$0..<min($0 + 4, rest.count)])
            }
            return (listed, grouped)
        }

        func fits(_ layout: (listed: [BarKey], grouped: [[BarKey]])) -> Bool {
            let rows = layout.listed.count + layout.grouped.count + (extended.isEmpty ? 0 : 1)
            return CGFloat(rows + 1) * Self.menuRowHeight <= room
        }

        let layout =
            [common.count, 8, 4].map(split(listing:)).first(where: fits) ?? split(listing: 4)

        var items: [UIMenuElement] = layout.listed.map(menuAction(for:))
        for (group, title)
            in (layout.grouped.map { ($0, Self.rangeTitle($0)) }
            + (extended.isEmpty ? [] : [(extended, Self.rangeTitle(extended))]))
        {
            items.append(
                UIMenu(
                    title: title, image: UIImage(systemName: "function"),
                    children: group.map(menuAction(for:))))
        }
        return items
    }

    /// "F9–F12", for a run of F keys.
    private static func rangeTitle(_ keys: [BarKey]) -> String {
        let first = keys.first?.name ?? ""
        let last = keys.last?.name ?? ""
        return first == last ? first : "\(first)–\(last)"
    }

    private func menuAction(for key: BarKey) -> UIAction {
        let action = UIAction(title: key.name, image: menuImage(for: key)) { [weak self] _ in
            self?.press(key)
        }

        if key.modifier != nil {
            action.state = isOn(key) ? .on : .off
        }
        if key == .copy, terminal?.hasActiveSelection != true {
            action.attributes = .disabled
        }
        return action
    }

    /// The key's icon, but for a character the character itself, drawn in its
    /// place: More shows nothing else that says what it types.
    private func menuImage(for key: BarKey) -> UIImage? {
        if key == .tab, tabIsShifted {
            return UIImage(systemName: BarKey.backTabSymbol)
        }
        guard key.group == .characters else { return key.icon }

        if let drawn = Self.characterIcons[key] {
            return drawn
        }
        let icon = BarKey.textIcon(
            key.glyph, font: .monospacedSystemFont(ofSize: 17, weight: .medium))
        Self.characterIcons[key] = icon
        return icon
    }

    // MARK: Pressing

    private func press(_ key: BarKey) {
        UIDevice.current.playInputClick()

        // The clipboard as the edit menu has it, through SwiftTerm, leaving any modifiers for the
        // next key. Paste is SwiftTerm's, bracketed when the guest has asked for that; it reads the
        // pasteboard itself, so iOS asks first when what's there came from another app.
        if key.group == .clipboard {
            switch key {
            case .copy: terminal?.copy(nil)
            case .paste: terminal?.paste(nil)
            default: terminal?.selectAll(nil)
            }
            return
        }

        if let modifier = key.modifier {
            toggle(modifier)
            return
        }

        // Caps lock on the software keyboard turns Tab round, as Shift does, but no other key.
        let capsLock: KeyModifiers = key == .tab && SoftKeyboard.isShiftLocked ? .shift : []
        send(key, with: pendingModifiers().union(capsLock))
    }

    /// An arrow from the pad. The modifiers it was first pressed with stay on
    /// it until the finger lifts, through repeats and changes of direction, as
    /// Shift held on a keyboard would.
    private func pressArrow(_ key: BarKey, repeating: Bool) {
        if !repeating {
            UIDevice.current.playInputClick()
        }
        if heldArrowModifiers == nil {
            heldArrowModifiers = pendingModifiers()
        }
        send(key, with: heldArrowModifiers ?? [])
    }

    private func send(_ key: BarKey, with modifiers: KeyModifiers) {
        guard let terminal else { return }

        terminal.send(key.sequence(with: modifiers, mode: terminal.keyEncodingMode))
        terminal.clearModifiers()
        refreshModifiers()
    }

    /// The modifiers for a key from the bar: those set on the bar or the
    /// software keyboard, and any held on a hardware keyboard.
    private func pendingModifiers() -> KeyModifiers {
        (terminal?.pendingModifiers ?? []).union(Self.hardwareModifiers)
    }

    /// The modifiers held down on a hardware keyboard, if one is attached.
    private static var hardwareModifiers: KeyModifiers {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return [] }

        func held(_ codes: GCKeyCode...) -> Bool {
            codes.contains { input.button(forKeyCode: $0)?.isPressed == true }
        }

        var modifiers: KeyModifiers = []
        if held(.leftShift, .rightShift) { modifiers.insert(.shift) }
        if held(.leftAlt, .rightAlt) { modifiers.insert(.alt) }
        if held(.leftControl, .rightControl) { modifiers.insert(.ctrl) }
        if held(.leftGUI, .rightGUI) { modifiers.insert(.superKey) }
        return modifiers
    }

    private func toggle(_ modifier: KeyModifiers) {
        guard let terminal else { return }

        switch modifier {
        case .shift: terminal.shiftModifier.toggle()
        case .alt: terminal.metaModifier.toggle()
        case .ctrl: terminal.controlModifier.toggle()
        case .superKey: terminal.superModifier.toggle()
        default: break
        }
        refreshModifiers()
    }

    private func isOn(_ key: BarKey) -> Bool {
        guard let terminal else { return false }

        switch key {
        case .shift: return terminal.shiftModifier
        case .alt: return terminal.metaModifier
        case .ctrl: return terminal.controlModifier
        case .superKey: return terminal.superModifier
        default: return false
        }
    }

    /// Brings the modifier buttons, Tab, and More's ticks into line with the
    /// terminal, which turns modifiers off by itself once they've been used.
    private func refreshModifiers() {
        // Lit while armed, and while held on a hardware keyboard or riding on an arrow the pad is
        // still holding down: the bar shows everything that's on, not only what it was asked for.
        let held = Self.hardwareModifiers.union(heldArrowModifiers ?? [])
        // At once, rather than as UIKit would animate it: turning glass on and off otherwise has it
        // form and fade a beat after the tap, which reads as the key being slow. Updated now, in
        // this pass, and every time, so that a changed accent is redrawn too.
        UIView.performWithoutAnimation {
            for (key, button) in modifierButtons {
                button.isSelected = isOn(key) || key.modifier.map(held.contains) == true
                button.updateConfiguration()
                button.layoutIfNeeded()
            }
        }
        refreshTab(force: true)
    }

    /// Turns Tab round while any Shift is on: the bar's, the software
    /// keyboard's or its caps lock, or one held on a hardware keyboard.
    private func refreshTab(force: Bool = false) {
        let shifted =
            pendingModifiers().union(heldArrowModifiers ?? []).contains(.shift)
            || SoftKeyboard.isShiftLocked
        guard force || shifted != tabIsShifted else { return }

        tabIsShifted = shifted
        tabButton?.configuration?.image = UIImage(
            systemName: shifted ? BarKey.backTabSymbol : BarKey.tab.symbol ?? "")
        tabButton?.accessibilityLabel = shifted ? "Shift-Tab" : BarKey.tab.name
        rebuildMenu()
    }

    // MARK: Following changes

    private func observe() {
        let center = NotificationCenter.default

        for name in [
            Notification.Name.terminalViewControlModifierReset, .terminalViewMetaModifierReset,
            TctiTermView.modifiersDidChange,
        ] {
            center.addObserver(forName: name, object: terminal, queue: .main) { [weak self] _ in
                self?.refreshModifiers()
            }
        }

        for name in [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.didBecomeActiveNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.watchSoftShift()
            }
        }

        center.addObserver(forName: Accent.didChange, object: nil, queue: .main) {
            [weak self] _ in
            self?.tintColor = Accent.custom
            self?.rails.tintColor = Accent.custom
            self?.refreshModifiers()
        }

        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateAttachment()
                self?.watchHardwareModifiers()
            }
        }
        watchHardwareModifiers()

        // Every save of every setting lands here, from whatever thread made it, so only the two
        // this bar cares about are acted on, and only when they've actually changed.
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }

            if BarKey.pinned != pinned {
                rebuild()
            }

            let hides = AppSetting.hideKeyBarWithHardwareKeyboard.bool
            if hides != hidesWithHardwareKeyboard {
                hidesWithHardwareKeyboard = hides
                updateAttachment()
            }
        }
    }

    /// The modifier keys GameController reports going down and up.
    private static let modifierKeys: Set<GCKeyCode> = [
        .leftShift, .rightShift, .leftAlt, .rightAlt, .leftControl, .rightControl, .leftGUI,
        .rightGUI,
    ]

    /// The hardware modifier pressed and not yet released, with no other key in
    /// between: a tap in progress, if it's let go next.
    private var tappingModifier: GCKeyCode?

    /// Watches a hardware keyboard's modifiers, from GameController, as they
    /// happen rather than when the bar next happens to look: to light the bar's
    /// while they're held, and so that tapping one turns off the same modifier
    /// where the bar has it armed. A modifier held while another key is pressed
    /// is being used with it, not tapped, and leaves the bar alone.
    private func watchHardwareModifiers() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = {
            [weak self] _, _, code, pressed in
            DispatchQueue.main.async { self?.hardwareKeyChanged(code, pressed: pressed) }
        }
    }

    private func hardwareKeyChanged(_ code: GCKeyCode, pressed: Bool) {
        guard Self.modifierKeys.contains(code) else {
            if pressed { tappingModifier = nil }
            return
        }

        if pressed {
            tappingModifier = code
        } else if tappingModifier == code {
            tappingModifier = nil
            disarm(Self.modifier(for: code))
        }
        refreshModifiers()
    }

    /// The modifier a hardware modifier key is.
    private static func modifier(for code: GCKeyCode) -> KeyModifiers {
        switch code {
        case .leftShift, .rightShift: .shift
        case .leftAlt, .rightAlt: .alt
        case .leftControl, .rightControl: .ctrl
        default: .superKey
        }
    }

    /// Turns off one of the bar's modifiers, if it's on.
    private func disarm(_ modifier: KeyModifiers) {
        guard let terminal else { return }

        switch modifier {
        case .shift: terminal.shiftModifier = false
        case .alt: terminal.metaModifier = false
        case .ctrl: terminal.controlModifier = false
        default: terminal.superModifier = false
        }
    }

    /// Puts the bar on the terminal, or takes it off while a hardware keyboard
    /// is attached and the setting says to.
    ///
    /// iOS keeps an input accessory on screen when a hardware keyboard stands
    /// in for the software one, as a strip along the bottom; taking it off is
    /// what hides it there.
    private func updateAttachment() {
        guard let terminal else { return }

        let hide = hidesWithHardwareKeyboard && GCKeyboard.coalesced != nil
        let wanted: UIView? = hide ? nil : self
        guard terminal.inputAccessoryView !== wanted else { return }

        terminal.inputAccessoryView = wanted
        terminal.reloadInputViews()
    }

    // MARK: UIInputViewAudioFeedback

    var enableInputClicksWhenVisible: Bool { true }
}

// MARK: - More

/// More, with its menu kept clear of the bar.
///
/// A menu grows out of its source, and a button's source is the button, so it
/// opens over the button and the capsule around it. More's source is instead an
/// empty sliver just above the capsule, with the menu attached there, so the
/// bar stays in view while the menu is open. On the right rail, the sliver is
/// to the capsule's left instead, and as wide as the menu; see `menuWidth`.
private final class MoreButton: UIButton {

    /// How far above the button, and its capsule, the menu starts.
    private static let clearance: CGFloat = 8

    /// A menu's width. iOS aligns a menu with its source's leading edge, then
    /// keeps it on screen, which pushed a menu from a thin sliver back over
    /// the rail. A source this wide, ending beside the capsule, makes the menu
    /// end there too.
    private static let menuWidth: CGFloat = 248

    /// Whether the menu is open, so a hardware keyboard's Esc can close it.
    private(set) var isMenuOpen = false

    /// Where the menu's bottom goes when it opens to the side, from the right
    /// rail, as a y in a stationary view; nil to open above. It's the
    /// capsule's bottom once iOS has hidden the keyboard for the menu, so the
    /// rails settle level with it.
    var sideways: (bottom: CGFloat, space: UIView)?

    /// Called as the menu is created, before it opens, and as it closes.
    var menuWillOpen: () -> Void = {}
    var menuWillClose: () -> Void = {}

    private var anchor: CGPoint {
        guard let sideways else { return CGPoint(x: bounds.midX, y: -Self.clearance) }

        let bottom = convert(CGPoint(x: 0, y: sideways.bottom), from: sideways.space).y
        return CGPoint(x: bounds.minX - Self.clearance - Self.menuWidth / 2, y: bottom)
    }

    override func menuAttachmentPoint(for configuration: UIContextMenuConfiguration) -> CGPoint {
        anchor
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        source()
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        source()
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        menuWillOpen()
        return super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(
            interaction, willDisplayMenuFor: configuration, animator: animator)
        isMenuOpen = true
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        isMenuOpen = false
        menuWillClose()
    }

    /// The empty sliver the menu grows from and goes back into.
    private func source() -> UITargetedPreview {
        let size = CGSize(width: sideways == nil ? bounds.width : Self.menuWidth, height: 1)
        let sliver = UIView(frame: CGRect(origin: .zero, size: size))
        sliver.backgroundColor = .clear

        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedPreview(
            view: sliver, parameters: parameters,
            target: UIPreviewTarget(container: self, center: anchor))
    }
}

// MARK: - Rails

/// The transparent view the rails are drawn in, passing any touch that misses
/// a capsule through to the terminal.
private final class RailsView: UIView {

    /// The capsules, the only views that take touches.
    var capsules: [UIView] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event),
            capsules.contains(where: { hit.isDescendant(of: $0) })
        else { return nil }
        return hit
    }

    /// Sizes the glass container to fill the view.
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.frame = bounds }
    }
}

// MARK: - The arrow pad

/// How long an arrow on the pad is held before it repeats, as chosen in
/// Settings > Keyboard.
enum ArrowRepeat {

    /// The range on offer, in steps of a tenth of a second.
    static let shortest: TimeInterval = 0.1
    static let longest: TimeInterval = 1
    static let step: TimeInterval = 0.1

    /// The default, in milliseconds, which is how it's saved.
    static let defaultDelay = 300

    /// The chosen delay, held to the range on offer whatever is saved.
    static var delay: TimeInterval {
        get {
            let saved = TimeInterval(AppSetting.arrowRepeatDelay.integer) / 1000
            return min(max(saved, shortest), longest)
        }
        set {
            AppSetting.arrowRepeatDelay.set(Int((newValue * 1000).rounded()))
        }
    }

    /// A delay as Settings shows it.
    static func label(_ delay: TimeInterval) -> String {
        String(format: "%.1f s", delay)
    }
}

/// All four arrow keys in one button's space.
///
/// Press, then slide the way you want to go: the key is sent as soon as the
/// finger leaves the middle, and repeats for as long as it's held there.
/// Sliding round to another side changes key without lifting, and back to the
/// middle stops.
private final class ArrowPad: UIButton {

    /// Sends an arrow: first as the direction is chosen, then as it repeats.
    var press: (BarKey, _ repeating: Bool) -> Void = { _, _ in }

    /// The finger has lifted.
    var release: () -> Void = {}

    /// How far the finger has to move before it means a direction.
    private static let deadZone: CGFloat = 10

    /// The pace a held arrow repeats at, once it starts; see `ArrowRepeat` for
    /// how long until it does.
    private static let repeatInterval: TimeInterval = 0.07

    /// One arrow per direction, laid out as a cross.
    private let arrows: [BarKey: UIImageView] = Dictionary(
        uniqueKeysWithValues: [BarKey.up, .down, .left, .right].map { key in
            let arrow = UIImageView(image: UIImage(systemName: key.symbol ?? ""))
            arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: 8, weight: .semibold)
            arrow.contentMode = .center
            arrow.isUserInteractionEnabled = false
            return (key, arrow)
        })

    /// How far each arrow sits from the middle.
    private static let spread: CGFloat = 7

    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private var origin = CGPoint.zero
    private var repeatTimer: Timer?

    private var direction: BarKey? {
        didSet {
            guard direction != oldValue else { return }
            directionChanged()
        }
    }

    init() {
        super.init(frame: .zero)

        arrows.values.forEach(addSubview)
        highlight()

        // Highlighted under a pointer, as the bar's buttons are. A button rather than a plain
        // control for this alone: an interaction added to a control never showed one.
        KeyBar.hover(self)

        isAccessibilityElement = true
        accessibilityLabel = BarKey.arrows.name
        accessibilityCustomActions = [BarKey.up, .down, .left, .right].map { key in
            UIAccessibilityCustomAction(name: key.name) { [weak self] _ in
                self?.press(key, false)
                self?.release()
                return true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this pad is built in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let size = CGSize(width: Self.spread * 1.6, height: Self.spread * 1.6)
        for (key, arrow) in arrows {
            var center = CGPoint(x: bounds.midX, y: bounds.midY)
            switch key {
            case .up: center.y -= Self.spread
            case .down: center.y += Self.spread
            case .left: center.x -= Self.spread
            default: center.x += Self.spread
            }
            arrow.bounds = CGRect(origin: .zero, size: size)
            arrow.center = center
        }
    }

    /// All four at rest; while one is held, it in the tint and the others faded
    /// back.
    private func highlight() {
        for (key, arrow) in arrows {
            switch direction {
            case nil: arrow.tintColor = .label
            case key: arrow.tintColor = .tintColor
            default: arrow.tintColor = .tertiaryLabel
            }
        }
    }

    // MARK: Tracking

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        origin = touch.location(in: self)
        haptics.prepare()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        direction = direction(towards: touch.location(in: self))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        direction = nil
        release()
    }

    override func cancelTracking(with event: UIEvent?) {
        direction = nil
        release()
    }

    /// Whichever way the finger has gone furthest from where it came down, once
    /// it's out of the middle.
    private func direction(towards point: CGPoint) -> BarKey? {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        guard max(abs(dx), abs(dy)) >= Self.deadZone else { return nil }

        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .up : .down
    }

    private func directionChanged() {
        repeatTimer?.invalidate()
        repeatTimer = nil

        highlight()

        guard let direction else { return }
        haptics.impactOccurred()
        press(direction, false)

        schedule(after: ArrowRepeat.delay) { [weak self] in
            self?.schedule(every: Self.repeatInterval) { self?.press(direction, true) }
        }
    }

    // MARK: Repeating

    /// In the common modes, so that repeating carries on through anything else
    /// the run loop is tracking at the time.
    private func schedule(after delay: TimeInterval, _ fire: @escaping () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in fire() }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func schedule(every interval: TimeInterval, _ fire: @escaping () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in fire() }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }
}
