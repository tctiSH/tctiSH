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
    private static var height: CGFloat { capsuleHeight + verticalMargin * 2 }

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

    /// Whether More's menu is open.
    var isMenuOpen: Bool { more.isMenuOpen }

    /// Closes More's menu, as a hardware keyboard's Esc does.
    func closeMenu() {
        more.contextMenuInteraction?.dismissMenu()
    }

    /// Where the capsules are drawn, in the bar's coordinates. Everything else
    /// is see-through.
    var capsuleFrames: [CGRect] {
        [leading, trailing].filter { !$0.isHidden }.map(\.frame)
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

        Self.style(dismiss, symbol: "keyboard.chevron.compact.down", label: "Hide Keyboard")
        dismiss.addAction(
            UIAction { [weak self] _ in _ = self?.terminal?.resignFirstResponder() },
            for: .touchUpInside)

        trailing.contentView.addSubview(dismiss)

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

    /// Taller by whatever of the safe area beneath it the bar keeps clear of.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height + bottomInset)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

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
        trailing.isHidden = merged

        if merged {
            let buttons = pinnedViews + [more, dismiss]
            let width = Self.capsuleWidth(buttons: buttons.count)
            buttons.forEach(leading.contentView.addSubview)
            leading.frame = CGRect(
                x: content.midX - width / 2, y: content.minY, width: width,
                height: Self.capsuleHeight)
            lay(out: buttons)
        } else {
            trailing.contentView.addSubview(dismiss)
            trailing.frame = CGRect(
                x: content.maxX - Self.trailingWidth, y: content.minY,
                width: Self.trailingWidth, height: Self.capsuleHeight)
            dismiss.frame = trailing.bounds

            leading.frame = CGRect(
                x: content.minX, y: content.minY,
                width: Self.capsuleWidth(buttons: pinnedViews.count + 1),
                height: Self.capsuleHeight)
            lay(out: pinnedViews + [more])
        }

        if #unavailable(iOS 26.0) {
            leading.layer.cornerRadius = Self.capsuleHeight / 2
            trailing.layer.cornerRadius = Self.capsuleHeight / 2
        }

        didMove?()
    }

    /// Lines buttons up along their capsule.
    private func lay(out views: [UIView]) {
        for (index, view) in views.enumerated() {
            view.frame = CGRect(
                x: Self.capsuleInset + CGFloat(index) * Self.buttonWidth, y: 0,
                width: Self.buttonWidth, height: Self.capsuleHeight)
        }
    }

    // MARK: Building

    /// Starts again from what's saved. Layout then puts back as much as fits.
    private func rebuild() {
        pinned = BarKey.pinned
        shown = []
        rebuildPinned()
        setNeedsLayout()
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
        let room = (screenFrame?.minY ?? 0) - (window?.safeAreaInsets.top ?? 0)

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
/// bar stays in view while the menu is open.
private final class MoreButton: UIButton {

    /// How far above the button, and its capsule, the menu starts.
    private static let clearance: CGFloat = 8

    /// Whether the menu is open, so a hardware keyboard's Esc can close it.
    private(set) var isMenuOpen = false

    private var anchor: CGPoint { CGPoint(x: bounds.midX, y: -Self.clearance) }

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
    }

    /// The empty sliver the menu grows from and goes back into.
    private func source() -> UITargetedPreview {
        let sliver = UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 1))
        sliver.backgroundColor = .clear

        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedPreview(
            view: sliver, parameters: parameters,
            target: UIPreviewTarget(container: self, center: anchor))
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
