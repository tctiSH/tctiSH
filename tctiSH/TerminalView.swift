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
        self.terminalDelegate = self

        // Handle settings changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(TctiTermView.applySettings),
            name: UserDefaults.didChangeNotification, object: nil)
        applySettings()

        // Make sure the terminal looks the way it should before anything's displayed.
        setUpTheming()

        setUpPointer()

        // Observe by selector rather than with a block: NotificationCenter removes a selector
        // observer when the observer is freed, but keeps a block observer until it is removed
        // explicitly, and a terminal is freed when its TTY is closed.
        NotificationCenter.default.addObserver(
            self, selector: #selector(accentChanged), name: Accent.didChange, object: nil)
    }

    @objc private func accentChanged() {
        selectionHandleColor = Accent.color
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

        let blocksize = 1024
        var next = bytes.startIndex
        while next < bytes.endIndex {
            let end = min(next + blocksize, bytes.endIndex)
            feed(byteArray: bytes[next..<end])
            next = end
        }
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

    /// Sets up use of the user's theme.
    func setUpTheming() {
        // FIXME: have this be user-specifiable
        let theme = DefaultThemes.solzariedDark
        self.installColors(theme.ansi)

        let t = getTerminal()

        t.foregroundColor = theme.foreground
        t.backgroundColor = theme.background

        self.nativeBackgroundColor = makeUIColor(theme.background)
        self.nativeForegroundColor = makeUIColor(theme.foreground)
        self.layer.backgroundColor = makeUIColor(theme.background).cgColor
        self.layer.borderColor = self.layer.backgroundColor
        self.layer.shadowColor = self.layer.backgroundColor
        self.backgroundColor = self.nativeBackgroundColor

        self.selectedTextBackgroundColor = makeUIColor(theme.selectionColor)

        // SwiftTerm draws selected text black unless told otherwise, which on the theme's dark
        // selection is next to invisible.
        self.selectedTextForegroundColor = makeUIColor(theme.selectedText)

        // SwiftTerm's selection handles are a fixed blue, rather than the tint, so they're told.
        self.selectionHandleColor = Accent.color
        self.caretColor = makeUIColor(theme.cursor)
    }

    // Helper that converts a SwiftTerm color into a UI color.
    private func makeUIColor(_ color: SwiftTerm.Color) -> UIColor {
        UIColor(
            red: CGFloat(color.red) / 65535.0,
            green: CGFloat(color.green) / 65535.0,
            blue: CGFloat(color.blue) / 65535.0,
            alpha: 1.0)
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
        transport?.send(data)
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
