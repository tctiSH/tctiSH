//
// Terminal view for tctiSH: one TTY's screen, connected to Linux through a transport.
//
//  Copyright © 2022 Kate Temkin <k@ktemkin.com>.
//  Copyright © 2020 Miguel de Icaza.
//

import Foundation
import UIKit
import AVKit
import SwiftTerm

/// Termainal view that behaves like an Xterm into our linux environment.
public class TctiTermView: TerminalView, TerminalViewDelegate {

    // MARK: Holding the keyboard

    /// While set, the terminal refuses to give up focus, so that opening More's
    /// menu from a rail doesn't take it.
    var holdsKeyboard = false

    public override var canResignFirstResponder: Bool {
        !holdsKeyboard && super.canResignFirstResponder
    }

    // MARK: Modifiers from the key bar

    /// Posted when Shift or Meta, the two modifiers kept here, change.
    static let modifiersDidChange = Notification.Name("io.ara.tctish.terminalModifiersDidChange")

    /// Shift from the key bar, for the next keystroke.
    var shiftModifier = false {
        didSet {
            guard shiftModifier != oldValue else { return }
            NotificationCenter.default.post(name: TctiTermView.modifiersDidChange, object: self)
        }
    }

    /// Meta, or Windows, from the key bar, for the next keystroke: the key
    /// Kitty and xterm call super.
    var superModifier = false {
        didSet {
            guard superModifier != oldValue else { return }
            NotificationCenter.default.post(name: TctiTermView.modifiersDidChange, object: self)
        }
    }

    /// Every modifier the next keystroke will have.
    var pendingModifiers: KeyModifiers {
        var modifiers: KeyModifiers = []
        if shiftModifier || (SoftKeyboard.isShifted && !SoftKeyboard.isShiftLocked) {
            modifiers.insert(.shift)
        }
        if metaModifier { modifiers.insert(.alt) }
        if controlModifier { modifiers.insert(.ctrl) }
        if superModifier { modifiers.insert(.superKey) }
        return modifiers
    }

    /// Lets go of every modifier, once a keystroke has used them.
    func clearModifiers() {
        controlModifier = false
        metaModifier = false
        shiftModifier = false
        superModifier = false
        SoftKeyboard.releaseShift()
    }

    /// How keys are to be encoded, from the guest's current modes.
    var keyEncodingMode: KeyEncodingMode {
        let terminal = getTerminal()

        let kitty = terminal.keyboardEnhancementFlags

        // SwiftTerm keeps DECKPAM to itself. The cursor mode stands in for it: a program that wants
        // either sends terminfo's smkx, which in xterm-256color sets both.
        return KeyEncodingMode(
            applicationCursor: terminal.applicationCursor,
            applicationKeypad: terminal.applicationCursor,
            kitty: !kitty.isEmpty,
            kittyAllKeys: kitty.contains(.reportAllKeys),
            kittyText: kitty.contains(.reportAllKeys) && kitty.contains(.reportText))
    }

    /// Applies the key bar's Shift and Meta, and Ctrl and Alt together, to a
    /// typed character.
    public override func insertText(_ text: String) {
        var modifiers: KeyModifiers = []
        if shiftModifier { modifiers.insert(.shift) }
        if metaModifier { modifiers.insert(.alt) }
        if controlModifier { modifiers.insert(.ctrl) }
        if superModifier { modifiers.insert(.superKey) }

        let ours = shiftModifier || superModifier || (controlModifier && metaModifier)
        guard ours, markedTextRange == nil, text.count == 1, let character = text.first else {
            shiftModifier = false
            superModifier = false
            super.insertText(text)
            return
        }

        clearModifiers()
        send(BarKey.character(character, modifiers, mode: keyEncodingMode))
    }

    /// Applies the key bar's modifiers to a hardware keyboard's key.
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard controlModifier || metaModifier || shiftModifier || superModifier,
            presses.count == 1, let key = presses.first?.key,
            !key.modifierFlags.contains(.command), let bytes = barSequence(for: key)
        else {
            super.pressesBegan(presses, with: event)
            return
        }

        clearModifiers()
        send(bytes)
    }

    /// What a hardware key sends with the bar's modifiers, or nil if it's one
    /// to leave to SwiftTerm: Return, Backspace and the like.
    private func barSequence(for key: UIKey) -> [UInt8]? {
        var modifiers: KeyModifiers = []
        if shiftModifier || key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if metaModifier || key.modifierFlags.contains(.alternate) { modifiers.insert(.alt) }
        if controlModifier || key.modifierFlags.contains(.control) { modifiers.insert(.ctrl) }
        if superModifier || key.modifierFlags.contains(.command) { modifiers.insert(.superKey) }

        if let barKey = BarKey(hardware: key.keyCode) {
            return barKey.sequence(with: modifiers, mode: keyEncodingMode)
        }

        // What the key types, by the keyboard's layout, Shift and caps lock included, where nothing
        // else held changes it: Shift and 1 is "!". With Ctrl, Option or Command held, the key as
        // it is, as those turn it into something else. The key itself either way, for the Kitty
        // protocol's code.
        let base = key.charactersIgnoringModifiers
        let shiftOnly = key.modifierFlags.subtracting([.shift, .alphaShift, .numericPad]).isEmpty
        let characters = shiftOnly ? key.characters : base
        guard characters.count == 1, let character = characters.first,
            let scalar = character.unicodeScalars.first,
            scalar.value >= 0x20, scalar.value != 0x7f
        else { return nil }

        return BarKey.character(
            character, modifiers, mode: keyEncodingMode, key: base.count == 1 ? base.first : nil)
    }

    var pipController: AVPictureInPictureController?

    /// The current working directory, if one is known/available.
    private var _cwd: String?
    public var cwd: String? {
        get {
            return _cwd
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame, font: UIFont(name: "Menlo-Regular", size: 14))
        isMade = true
        self.terminalDelegate = self

        // Handle settings changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(TctiTermView.applySettings),
            name: UserDefaults.didChangeNotification, object: nil)
        applySettings()

        // Make sure the terminal looks the way it should before anything's displayed.
        applyTheme()

        // SwiftTerm draws its selection handles in a fixed blue rather than the tint, so they're
        // given the accent.
        selectionHandleColor = Accent.color

        setUpPointer()

        // Observe by selector rather than with a block: NotificationCenter removes a selector
        // observer when the observer is freed, but keeps a block observer until it is removed
        // explicitly, and a terminal is freed when its TTY is closed.
        NotificationCenter.default.addObserver(
            self, selector: #selector(accentChanged), name: Accent.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillEnterForeground),
            name: UIScene.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme), name: TerminalThemes.didChange, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TctiTermView, _) in
            view.applyTheme()
        }
    }

    @objc private func accentChanged() {
        selectionHandleColor = Accent.color
    }

    /// Restarts the cursor's blink as this terminal's window comes back from
    /// the background as Core Animation may have stopped it.
    @objc private func sceneWillEnterForeground(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else {
            return
        }
        // Setting this, even to what it was, has SwiftTerm restart the blink.
        caretViewTracksFocus = caretViewTracksFocus
    }

    // MARK: Transport

    /// The transport that carries this terminal's bytes to and from Linux.
    /// Setting it detaches the previous transport from this view.
    var transport: TerminalTransport? {
        didSet {
            if oldValue?.terminal === self {
                oldValue?.terminal = nil
            }
            transport?.terminal = self
        }
    }

    /// Called when bytes arrive from the far end, unless they are all BEL
    /// characters.
    var onOutput: (() -> Void)?

    /// Called when the far end rings the bell.
    var onBell: (() -> Void)?

    /// Called when something is typed or pasted into the terminal. Not called
    /// for what the terminal answers by itself, such as a shell's question
    /// about where the cursor is.
    var onTyping: (() -> Void)?

    /// Set while SwiftTerm answers by itself, as it does to a question about
    /// where the cursor is. The answer goes through `send(source:data:)` the
    /// same as typing does.
    private var answering = false

    /// Feeds bytes from the transport into the terminal.
    ///
    /// The bytes are fed in 1 KB chunks, so that a large burst is parsed a
    /// piece at a time rather than all at once before anything is drawn.
    func receive(_ bytes: ArraySlice<UInt8>) {
        // Bytes that are all BEL only ring the bell, so they don't count as output: a TTY's status
        // shows a bell differently from output.
        if bytes.contains(where: { $0 != 0x07 }) {
            onOutput?()
        }

        // Output moves the view, so a snap to a row in progress goes there at once.
        finishSnap()
        let anchor = scrolledTo()

        // SwiftTerm scrolls the view as it takes the output in, which is not the user scrolling.
        moving = true
        let blocksize = 1024
        var next = bytes.startIndex
        while next < bytes.endIndex {
            let end = min(next + blocksize, bytes.endIndex)
            feed(byteArray: bytes[next..<end])
            next = end
        }
        moving = false

        if let anchor {
            hold(at: anchor)
        }
        // The output may have cleared the screen or the scrollback, leaving nothing to hold on to.
        isFollowing = swiftTermFollows
    }

    // MARK: Following new output

    /// Posted when a terminal starts or stops following new output, with the
    /// terminal as the object.
    static let followingDidChange = Notification.Name("io.ara.tctish.terminalFollowingDidChange")

    /// Whether new output scrolls the terminal to show it. Cleared when the
    /// user scrolls up from the bottom, and set again when they scroll back
    /// down to it, type, or `follow()` is called. Kept in step with SwiftTerm
    /// when something else moves the view, such as the find bar.
    ///
    /// SwiftTerm stops following only while a finger is on the screen, which
    /// leaves out a trackpad, a mouse wheel and the momentum of a flick. So
    /// once such a scroll comes to rest, SwiftTerm is told where it ended, and
    /// while this is clear the terminal is put back where it was after each
    /// piece of output.
    private(set) var isFollowing = true {
        didSet {
            guard isFollowing != oldValue else { return }
            placeEdgeFades()
            NotificationCenter.default.post(name: Self.followingDidChange, object: self)
        }
    }

    /// Set while output or this class moves the view, so that it isn't taken
    /// for the user scrolling.
    private var moving = false

    /// Whether SwiftTerm's initializer has finished. Until then there is no
    /// terminal to ask for rows, yet UIKit can already move the view, from
    /// `UIScrollView.init(frame:)`, which that initializer calls.
    private var isMade = false

    /// Tells SwiftTerm where a scroll it didn't follow came to rest; see
    /// `settle()`.
    private var settling: DispatchWorkItem?

    public override var contentOffset: CGPoint {
        didSet {
            if !moving, contentOffset.y != oldValue.y {
                scrollingDown = contentOffset.y > oldValue.y
            }
            noteScroll()
            placeEdgeFades()
        }
    }

    /// Whether the view last moved down, toward newer output, rather than up;
    /// the way a scroll that comes to rest between rows snaps.
    private var scrollingDown = false

    /// Scrolls to the oldest line kept, and stops following new output, as
    /// scrolling there by hand would. A program on the alternate screen has no
    /// scrollback to scroll through.
    func scrollToTop() {
        guard !getTerminal().isCurrentBufferAlternate, canScroll else { return }
        settling?.cancel()
        settling = nil
        cancelSnap()
        isFollowing = false

        moving = true
        scrollTo(row: 0)
        moving = false
    }

    /// Scrolls to the bottom, and follows new output from there.
    func follow() {
        settling?.cancel()
        settling = nil
        cancelSnap()
        isFollowing = true

        moving = true
        scrollTo(row: Int.max)
        moving = false
    }

    /// The height of a row, from the size SwiftTerm would like the terminal to
    /// be.
    private var rowHeight: CGFloat {
        let rows = getTerminal().rows
        return rows > 0 ? getOptimalFrameSize().height / CGFloat(rows) : 0
    }

    /// The row at the top of the screen, rounded as SwiftTerm rounds it: a
    /// pixel up, so that floating-point error can't make it the row above.
    private var topRow: Int {
        Int(((contentOffset.y + pixel) / rowHeight).rounded(.down))
    }

    /// A pixel, in points.
    private var pixel: CGFloat {
        1 / max(traitCollection.displayScale, 1)
    }

    private var isAtBottom: Bool {
        let bottom = max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
        return contentOffset.y >= bottom - rowHeight / 2
    }

    /// Whether SwiftTerm is following new output: the screen can't scroll, or
    /// it shows the bottom.
    private var swiftTermFollows: Bool {
        getTerminal().isCurrentBufferAlternate || !canScroll || scrollPosition >= 1
    }

    private var userIsScrolling: Bool {
        let state = panGestureRecognizer.state
        return state == .began || state == .changed || isDecelerating
    }

    /// Follows or stops following as the view moves. The user scrolls with the
    /// pan gesture (a finger, a trackpad or a mouse wheel) or a flick's
    /// momentum. Anything else goes through SwiftTerm, which knows where the
    /// view is by then: the find bar, a selection dragged past the edge, or
    /// SwiftTerm itself.
    private func noteScroll() {
        guard isMade, !moving, rowHeight > 0 else { return }
        // Whoever moved the view, a snap to a row no longer has the last word on where it goes.
        cancelSnap()
        guard userIsScrolling else {
            if settling == nil {
                isFollowing = swiftTermFollows
            }
            return
        }

        isFollowing = isAtBottom
        if !isFollowing, !isTracking {
            settleSoon()
        }
    }

    private func settleSoon() {
        settling?.cancel()
        let settling = DispatchWorkItem { [weak self] in self?.settle() }
        self.settling = settling
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: settling)
    }

    /// Once a scroll that SwiftTerm didn't follow has come to rest, tells it
    /// the row now at the top, so that it stays there. SwiftTerm keeps to whole
    /// rows, so the view first glides on to the next whole row the way it was
    /// going; see `snap`.
    private func settle() {
        settling = nil
        guard !userIsScrolling else {
            settleSoon()
            return
        }
        guard !isFollowing, rowHeight > 0 else { return }

        let height = rowHeight
        let rows = contentOffset.y / height
        let row = Int(
            scrollingDown
                ? (rows - pixel / height).rounded(.up) : (rows + pixel / height).rounded(.down))
        let bottom = max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let target = min(CGFloat(row) * height, bottom)

        guard abs(target - contentOffset.y) >= pixel else {
            rest(at: row)
            return
        }
        cancelSnap()
        snap = Snap(
            row: row, from: contentOffset.y, to: target, start: CACurrentMediaTime(),
            link: CADisplayLink(target: self, selector: #selector(stepSnap)))
        snap?.link.add(to: .main, forMode: .common)
    }

    /// A glide to a whole row, at the end of a scroll that came to rest between
    /// two. The view moves a frame at a time, as it does under a finger, since
    /// SwiftTerm draws what's on screen afresh as the view moves.
    private struct Snap {
        var row: Int
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval
        var link: CADisplayLink
    }

    private var snap: Snap?

    /// How long a snap to a row takes.
    private static let snapDuration: CFTimeInterval = 0.2

    @objc private func stepSnap() {
        guard let snap else { return }
        // A finger on the screen takes the view where it is. If it only taps, the view settles
        // again from there.
        guard !isTracking else {
            cancelSnap()
            settleSoon()
            return
        }
        let progress = min((CACurrentMediaTime() - snap.start) / Self.snapDuration, 1)
        // Easing out, as a scroll slows to a stop.
        let eased = 1 - pow(1 - progress, 3)

        moving = true
        contentOffset.y = snap.from + (snap.to - snap.from) * eased
        moving = false

        if progress >= 1 {
            finishSnap()
        }
    }

    /// Ends a snap in progress where it was going.
    private func finishSnap() {
        guard let snap else { return }
        cancelSnap()
        rest(at: snap.row)
    }

    /// Stops a snap in progress where it is, for something else moving the
    /// view.
    private func cancelSnap() {
        snap?.link.invalidate()
        snap = nil
    }

    /// Tells SwiftTerm `row` is at the top, which puts the view there.
    private func rest(at row: Int) {
        moving = true
        scrollTo(row: row, notifyAccessibility: false)
        moving = false
        isFollowing = swiftTermFollows
    }

    // MARK: Fading the edges

    /// Gradients at the top and bottom edges, a row high, that rows run under
    /// as they leave the screen, so that they fade into the background rather
    /// than being cut off. The screen is rarely a whole number of rows high, so
    /// one row or the other is usually only partly on it.
    ///
    /// The bottom one shows while the terminal isn't following new output, and
    /// the top one while there's anything above the screen: so the first row of
    /// a new terminal, and the last while following, are never faded. They sit
    /// at the edges of the view, which is where it clips what it draws.
    private let topFade = edgeFade()
    private let bottomFade = edgeFade()

    private static func edgeFade() -> CAGradientLayer {
        let fade = CAGradientLayer()
        fade.zPosition = 1
        fade.opacity = 0
        return fade
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        placeEdgeFades()
    }

    /// Puts the fades at the edges of what's on screen. They're placed in the
    /// scroll view's bounds, which move as it scrolls, so they're placed again
    /// on every scroll.
    private func placeEdgeFades() {
        guard isMade else { return }
        if topFade.superlayer == nil {
            layer.addSublayer(topFade)
            layer.addSublayer(bottomFade)
        }

        let height = rowHeight

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topFade.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
        bottomFade.frame = CGRect(
            x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
        topFade.opacity = bounds.minY > pixel ? 1 : 0
        bottomFade.opacity = isFollowing ? 0 : 1
        CATransaction.commit()
    }

    /// The row at the top of the screen, counted from the first line ever
    /// written so that it stays put as scrollback is trimmed, or nil if the
    /// terminal is following. A program using the alternate screen, as a
    /// full-screen one does, has no scrollback, so the terminal follows it.
    private func scrolledTo() -> Int? {
        let terminal = getTerminal()
        if terminal.isCurrentBufferAlternate {
            isFollowing = true
        }
        guard !isFollowing, rowHeight > 0 else { return nil }
        return topRow + terminal.buffer.totalLinesTrimmed
    }

    /// Puts the terminal back with `anchor`, from `scrolledTo()`, at the top of
    /// the screen, if output moved it.
    private func hold(at anchor: Int) {
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate, rowHeight > 0 else { return }
        let row = max(0, anchor - terminal.buffer.totalLinesTrimmed)
        guard terminal.buffer.yDisp != row || topRow != row else { return }

        moving = true
        scrollTo(row: row, notifyAccessibility: false)
        moving = false
    }

    /// Callback notified each time a setting is changed.
    ///
    /// Arrives on whichever thread changed the setting, often not the main one:
    /// the guest's font size comes in on the configuration server's queue, and
    /// the save bookkeeping writes from the monitor's. A font change resizes
    /// the terminal, which is UIKit's to do, so it is done on the main thread
    /// whatever thread this was called on.
    @objc
    func applySettings() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.applySettings() }
            return
        }

        // Font size: this TTY's override, or else the default from Settings.
        var new_size = CGFloat(fontSizeOverride ?? AppSetting.fontSize.integer)
        if new_size == 0 {
            new_size = self.font.pointSize
        }
        if new_size != self.font.pointSize {
            self.font = UIFont(name: self.font.fontName, size: new_size) ?? self.font
        }

        applyScrollback()
    }

    /// This TTY's font size, or nil for the default in Settings.
    var fontSizeOverride: Int? {
        didSet {
            guard fontSizeOverride != oldValue else { return }
            applySettings()
        }
    }

    /// This TTY's scrollback in standard lines, or nil for the default in
    /// Settings.
    var scrollbackOverride: Int? {
        didSet {
            guard scrollbackOverride != oldValue else { return }
            applyScrollback()
        }
    }

    /// The scrollback last given to SwiftTerm, in rows of the terminal's width
    /// rather than standard lines.
    private var appliedScrollback: Int?

    /// Sets SwiftTerm's scrollback from the setting, which is in standard
    /// lines.
    ///
    /// Every row SwiftTerm keeps holds a cell for every column, so the memory a
    /// row of scrollback costs grows with the terminal's width. The setting is
    /// a budget of standard 80-column lines.
    private func applyScrollback() {
        let standard = max(0, scrollbackOverride ?? AppSetting.scrollback.integer)

        let screen = window?.windowScene?.screen.bounds ?? UIScreen.main.bounds
        let cell = ("W" as NSString).size(withAttributes: [.font: font]).width
        let columns = cell > 0 ? max(1, Int(max(screen.width, screen.height) / cell)) : 80
        let lines = standard * Self.standardColumns / columns

        guard lines != appliedScrollback else { return }
        appliedScrollback = lines
        changeScrollback(lines)
    }

    /// The width, in columns, of a standard line of scrollback.
    static let standardColumns = 80

    // MARK: Trackpad and mouse

    /// Handles the trackpad and mouse gestures' questions and the right-click
    /// menu's.
    private let pointer = PointerSupport()

    /// The menu a right-click brings up.
    private var editMenu: UIEditMenuInteraction?

    /// Adds what SwiftTerm leaves out for a trackpad or mouse: selecting by
    /// dragging, and a right-click for the Copy and Paste menu.
    private func setUpPointer() {
        let drag = UIPanGestureRecognizer(target: self, action: #selector(pointerDragged(_:)))
        drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        drag.allowedScrollTypesMask = []
        pointer.terminal = self
        drag.delegate = pointer
        addGestureRecognizer(drag)

        panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]

        let secondary = UITapGestureRecognizer(
            target: self, action: #selector(secondaryClicked(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        addGestureRecognizer(secondary)

        let menu = UIEditMenuInteraction(delegate: pointer)
        addInteraction(menu)
        editMenu = menu
    }

    @objc private func pointerDragged(_ drag: UIPanGestureRecognizer) {
        let position = bufferPosition(at: drag.location(in: self))

        switch drag.state {
        case .began:
            _ = becomeFirstResponder()
            selection.selectionMode = .character
            selection.setSoftStart(bufferPosition: position)
        case .changed:
            selection.dragExtend(bufferPosition: position)
        case .ended, .cancelled:
            // A press that barely moved leaves a selection of nothing, which Copy would then put on
            // the clipboard in place of whatever was there.
            if !selection.hasSelectionRange {
                clearSelection()
            }
        default:
            break
        }
    }

    /// Copy while there's a selection, Paste, and Select All, as the pointer's
    /// context menu rather than the bar of buttons a long press gives.
    ///
    /// Through `UIEditMenuInteraction`, which shows itself as a context menu
    /// when a secondary click brings it up. SwiftTerm's menu is still the older
    /// `UIMenuController`, which only ever draws the touch bar.
    @objc private func secondaryClicked(_ click: UITapGestureRecognizer) {
        _ = becomeFirstResponder()
        editMenu?.presentEditMenu(
            with: UIEditMenuConfiguration(identifier: nil, sourcePoint: click.location(in: self)))
    }

    /// Copies the selection without the spaces at the ends of its lines.
    public override func copy(_ sender: Any?) {
        let text = selection.getSelectedText()
        guard hasActiveSelection, !text.isEmpty else {
            clearSelection()
            return
        }
        super.copy(sender)

        UIPasteboard.general.string = text.components(separatedBy: "\n")
            .map { line in
                var line = Substring(line)
                while let last = line.last, last == " " || last == "\t" {
                    line.removeLast()
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    /// All of the terminal's text, from the oldest line kept: each line as it
    /// was written, however many rows it wrapped onto, without the blanks at
    /// its end or the empty rows after the last.
    var transcript: String {
        let terminal = getTerminal()
        var lines: [String] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            let text = line.translateToString(skipNullCellsFollowingWide: true)
            if line.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += text
            } else {
                lines.append(text)
            }
            row += 1
        }

        // Cells nothing was written to read as NUL.
        var trimmed = lines.map { line in
            var line = Substring(line.replacingOccurrences(of: "\0", with: " "))
            while let last = line.last, last == " " || last == "\t" {
                line.removeLast()
            }
            return String(line)
        }
        while trimmed.last?.isEmpty == true {
            trimmed.removeLast()
        }
        return trimmed.map { $0 + "\n" }.joined()
    }

    /// What the right-click menu offers.
    fileprivate func editMenuActions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        if hasActiveSelection {
            actions.append(
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) {
                    [weak self] _ in self?.copy(nil)
                })
        }
        actions.append(
            UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) {
                [weak self] _ in self?.paste(nil)
            })
        actions.append(
            UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) {
                [weak self] _ in self?.selectAll(nil)
            })
        return actions
    }

    /// The cell under a point in the view, in buffer coordinates.
    ///
    /// The view scrolls, so a point in it is already a point in the whole
    /// buffer. SwiftTerm keeps its cell size to itself, but gives it away as
    /// the frame that would fit the terminal exactly.
    private func bufferPosition(at point: CGPoint) -> Position {
        let terminal = getTerminal()
        let fit = getOptimalFrameSize()
        let width = fit.width / CGFloat(max(terminal.cols, 1))
        let height = fit.height / CGFloat(max(terminal.rows, 1))
        guard width > 0, height > 0 else { return Position(col: 0, row: 0) }

        return Position(
            col: min(max(0, Int(point.x / width)), terminal.cols - 1),
            row: max(0, Int(point.y / height)))
    }

    func clear() {

        /// Sequence used to clear our terminal.
        let terminalClearSequence: ArraySlice<UInt8> = [27, 91, 72, 27, 91, 74]
        self.feed(byteArray: terminalClearSequence)

    }

    // MARK: Theme

    /// The colors last painted with, so that a change to a theme this terminal
    /// isn't using, or to a name, doesn't redraw it for nothing.
    private var appliedColors: [ThemeColor]?

    /// Paints the terminal with the theme chosen for the appearance iOS is in:
    /// the dark mode one or the light mode one.
    @objc func applyTheme() {
        let theme = TerminalThemes.selected(for: TerminalThemes.Appearance(of: self))
        guard theme.colors != appliedColors else { return }
        appliedColors = theme.colors

        installColors(theme.ansi.map(\.terminalColor))

        // These set the terminal's default colors too.
        let background = theme.background.uiColor
        nativeForegroundColor = theme.foreground.uiColor
        nativeBackgroundColor = background
        layer.backgroundColor = background.cgColor
        layer.borderColor = layer.backgroundColor
        layer.shadowColor = layer.backgroundColor
        backgroundColor = background
        // At once, as the background changes, rather than as Core Animation would fade them.
        let clear = background.withAlphaComponent(0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topFade.colors = [background.cgColor, clear.cgColor]
        bottomFade.colors = [clear.cgColor, background.cgColor]
        CATransaction.commit()

        selectedTextBackgroundColor = theme.selection.uiColor
        // SwiftTerm draws selected text black unless told otherwise, which on a dark selection is
        // next to invisible.
        selectedTextForegroundColor = theme.selectedText.uiColor

        caretColor = theme.cursor.uiColor
        caretTextColor = theme.cursorText.uiColor
    }

    /// Out of a window, a terminal takes the active scene's appearance. Moved
    /// into one, it takes that window's.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        applyTheme()
    }

    /// Compliance initializer for things that can do encoding/decoding.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Callback that occurs when the terminal is scrolled. Can be used to save
    /// the scrollback, if desired.
    public func scrolled(source: TerminalView, position: Double) {
        // Nothing to do here, yet.
    }

    /// Callback that occurs when a range of rows has been redrawn.
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        // Nothing to do here; the view redraws itself.
    }

    /// Callback that occurs when the far end rings the bell.
    public func bell(source: TerminalView) {
        onBell?()
    }

    /// Callback that occurs when the guest VM requests a terminal title change.
    public func setTerminalTitle(source: TerminalView, title: String) {
        Log.ui.note("terminal title is now \(title)")
    }

    /// Callback that occurs when the terminal's effective area has changed.
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {

        transport?.resize(cols: newCols, rows: newRows)
    }

    /// Sends what was typed to the far end, through the transport.
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !answering {
            onTyping?()
            // Typing goes back to the bottom, to show what is typed and what it answers.
            if !isFollowing {
                follow()
            }
        }
        transport?.send(data)
    }

    /// Sends what the terminal answers by itself, such as a report of where the
    /// cursor is, which isn't typing.
    public override func send(source: Terminal, data: ArraySlice<UInt8>) {
        answering = true
        defer { answering = false }
        super.send(source: source, data: data)
    }

    /// Callback that occurs when we receive OSC 7, which indicates the current
    /// working directory. The default tctiSH setup's shell integration
    /// generates OSC-7 each time the prompt is issue.
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        _cwd = directory
    }

    /// Callback that occurs when the guest copies with OSC 52, as tmux, vim and
    /// neovim do when they have no other clipboard to reach.
    ///
    /// Arrives already decoded from the base64 the escape carries. Anything
    /// that isn't text is dropped, as the pasteboard would only offer it back
    /// to the terminal as text anyway.
    public func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else {
            Log.ui.note("ignored an OSC 52 copy that wasn't UTF-8 (\(content.count) bytes)")
            return
        }

        DispatchQueue.main.async {
            UIPasteboard.general.string = text
        }
    }

    /// Callback that occurs when the guest asks for the clipboard with OSC 52.
    ///
    /// Refused unless Settings allows it, which by default it doesn't: the
    /// request can come from anything that prints in the terminal, including a
    /// remote machine reached over ssh, and the answer goes to whoever asked.
    /// iOS asks first only for what another app copied, and not at all once
    /// it's been told to allow pasting. Checking for text first doesn't count
    /// as a read, and saves asking when there's nothing to give.
    public func clipboardRead(source: TerminalView) -> Data? {
        guard AppSetting.allowClipboardRead.bool, UIPasteboard.general.hasStrings else {
            return nil
        }
        return UIPasteboard.general.string?.data(using: .utf8)
    }

    /// Callback that occurs when the user clicks on a URL or link in the tctiSH
    /// scrollback.
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let fixedup = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = NSURLComponents(string: fixedup) {
                if let nested = url.url {
                    UIApplication.shared.open(nested)
                }
            }
        }
    }

}

/// The terminal's trackpad and mouse handling, as delegate: kept apart from the
/// view so as not to collide with what SwiftTerm already answers there.
///
/// A pointer drag is left to the program in the terminal when it has asked for
/// the mouse, as htop and vim with `mouse=a` do, unless Shift is held: the
/// usual way past a program's mouse handling, and SwiftTerm's. Not even then,
/// if the program has asked for Shift as well (XTSHIFTESCAPE), as SwiftTerm
/// also honors.
private final class PointerSupport: NSObject, UIGestureRecognizerDelegate,
    UIEditMenuInteractionDelegate
{
    weak var terminal: TctiTermView?

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        terminal.map { UIMenu(children: $0.editMenuActions()) }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let terminal, terminal.allowMouseReporting,
            terminal.getTerminal().mouseMode != .off
        else { return true }

        return gestureRecognizer.modifierFlags.contains(.shift)
            && !terminal.getTerminal().mouseShiftCapture
    }
}
