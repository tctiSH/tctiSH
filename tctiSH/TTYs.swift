//
//  TTYs.swift
//  The TTYs, and the windows that show them: each window's TTYs, and which
//  one is selected and on screen.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

// MARK: - A TTY

/// One of the terminals the switcher shows.
///
/// Two belong to the system and always exist: the kernel log and QEMU's
/// monitor, which the switcher shows only if Settings says to. The rest belong
/// to the user, at most `userLimit` of them, and each is on a console device in
/// Linux (`hvc0`, `hvc1`, and so on), named for it unless Settings gives the
/// console another name.
final class TTY {

    enum Kind: Codable, Hashable {
        case kernelLog
        case vmManagement
        case user(Int)
    }

    /// The maximum number of user TTYs: one for each of the guest's consoles.
    static let userLimit = Int(TCTISH_CONSOLE_COUNT)

    /// The default scrollback, in standard 80-column lines.
    static let defaultScrollback = 2000

    let id: UUID
    let kind: Kind

    /// The name the user gave the TTY, or nil if it hasn't been renamed.
    fileprivate(set) var customName: String?

    fileprivate(set) var isPinned: Bool
    fileprivate(set) var isMuted: Bool

    /// The TTY's font size, and its scrollback in standard lines. Each is nil
    /// to use the default in Settings.
    fileprivate(set) var fontSize: Int? {
        didSet { view?.fontSizeOverride = fontSize }
    }
    fileprivate(set) var scrollback: Int? {
        didSet { view?.scrollbackOverride = scrollback }
    }

    /// Whether the TTY has rung the bell since it was last selected. Bells are
    /// ignored while it is muted, and muting it clears this.
    fileprivate(set) var hasBelled = false

    /// Whether output has arrived in the TTY since it was last selected.
    fileprivate(set) var hasUnseenOutput = false

    /// Goes up each time output arrives, the terminal is resized, or the TTY's
    /// font size changes, since each can change what the screen shows. A card
    /// compares it with the value it last drew at to tell whether its thumbnail
    /// is out of date.
    fileprivate(set) var outputCount = 0

    /// The TTY's terminal view. It is made once the view controller has said
    /// how big terminals are, or as the TTY is added if that is later.
    fileprivate(set) var view: TctiTermView!

    fileprivate init(
        id: UUID = UUID(), kind: Kind, customName: String? = nil, isPinned: Bool = false,
        isMuted: Bool = false, fontSize: Int? = nil, scrollback: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.customName = customName
        self.isPinned = kind.isSystem || isPinned
        self.isMuted = isMuted
        self.fontSize = fontSize
        self.scrollback = scrollback
    }

    var isSystem: Bool { kind.isSystem }

    /// The number of a user TTY's console, as in `hvc<number>`, or nil for a
    /// system TTY.
    var number: Int? {
        if case .user(let number) = kind { return number }
        return nil
    }

    /// The name of a user TTY's console in Linux, as in `hvc0`, or nil for a
    /// system TTY.
    var device: String? { number.map { "hvc\($0)" } }

    /// The name shown for the TTY: the user's name for it if it has been
    /// renamed, and its default name otherwise.
    var name: String { customName ?? defaultName }

    /// The name the TTY goes by until it is renamed: for a user TTY, the name
    /// Settings gives its console, or failing that the console's name.
    var defaultName: String {
        switch kind {
        case .kernelLog: "Kernel Log"
        case .vmManagement: "VM Management"
        case .user(let number): TTYs.defaultName(ofConsole: "hvc\(number)") ?? "hvc\(number)"
        }
    }

    /// The status icons to show for the TTY, in display order. A muted TTY
    /// shows the unseen-output dot, if it has unseen output, then the muted
    /// icon. An unmuted TTY that has rung the bell shows a single bell icon,
    /// which has a badge if there is also unseen output. Any other TTY shows
    /// just the dot, if it has unseen output.
    var statuses: [TTYStatus] {
        if isMuted {
            return (hasUnseenOutput ? [.unseenOutput] : []) + [.muted]
        }
        if hasBelled {
            return [hasUnseenOutput ? .bellAndOutput : .bell]
        }
        return hasUnseenOutput ? [.unseenOutput] : []
    }
}

extension TTY.Kind {
    var isSystem: Bool {
        if case .user = self { return false }
        return true
    }
}

// MARK: - A window's TTYs

/// The TTYs one window shows, in the switcher's order, and which of them is
/// selected and on screen. There is one for each scene session. It changes only
/// through `TTYs`.
///
/// A user TTY is in exactly one window. A system TTY is in at most one, and in
/// none while Settings hides it.
final class TTYWindow {

    /// The `persistentIdentifier` of the window's scene session, which lasts
    /// across launches. Nil until a scene adopts the window, as for the one
    /// made from what was saved before there were windows.
    fileprivate(set) var id: String?

    /// The system TTYs in the window: Kernel Log, then VM Management, if each
    /// is in it.
    fileprivate(set) var system: [TTY]

    /// The user TTYs in the window in switcher order: the pinned ones first,
    /// then the rest.
    fileprivate(set) var users: [TTY]

    fileprivate(set) var selected: TTY

    /// The frame every terminal in the window is given, set by the window's
    /// view controller. Every terminal is kept at this size, shown or not, so
    /// that each is ready to be shown and its thumbnail has the shape of the
    /// screen. A change counts toward each TTY's `outputCount`, so that the
    /// cards redraw their thumbnails.
    var terminalFrame: CGRect = .zero {
        didSet {
            guard terminalFrame != oldValue else { return }
            for tty in ordered {
                fit(tty.view, to: terminalFrame)
                tty.outputCount &+= 1
            }
        }
    }

    fileprivate init(id: String?, system: [TTY], users: [TTY], selected: TTY) {
        self.id = id
        self.system = system
        self.users = users
        self.selected = selected
    }

    /// The window's pinned user TTYs, and the unpinned ones, which the switcher
    /// shows as cards.
    var pinned: [TTY] { users.filter(\.isPinned) }
    var cards: [TTY] { users.filter { !$0.isPinned } }

    /// Every TTY in the window, in the switcher's order: the system TTYs, then
    /// the pinned ones, then the cards.
    var ordered: [TTY] { system + users }

    /// The TTYs that swiping across the switcher button and the keyboard
    /// shortcuts step through: the user TTYs, preceded by the system TTYs if
    /// that option is on in Settings.
    var stepOrder: [TTY] {
        AppSetting.stepThroughSystemTTYs.bool ? ordered : users
    }

    func contains(_ tty: TTY) -> Bool {
        ordered.contains { $0 === tty }
    }

    /// The window's name, in App Exposé, the window list and Move Terminal to:
    /// the selected TTY's, then how many other user TTYs the window has, then
    /// the system TTYs shown in its switcher, by name, or as System Terminals
    /// for both: "Default (and 2 Other Terminals and Kernel Log)".
    var title: String {
        let others = users.filter { $0 !== selected }.count
        // Only those shown in the switcher are in the window.
        let system = system.filter { $0 !== selected }

        var also: [String] = []
        switch others {
        case 0: break
        case 1: also.append("1 Other Terminal")
        default: also.append("\(others) Other Terminals")
        }
        switch system.count {
        case 0: break
        case 1: also.append(system[0].name)
        default: also.append("System Terminals")
        }

        let name = selected.name
        return also.isEmpty ? name : "\(name) (and \(also.joined(separator: " and ")))"
    }

    /// Whether any TTY in the window, other than the selected one, has rung the
    /// bell while unmuted and has not been selected since.
    var needsAttention: Bool {
        ordered.contains { $0 !== selected && !$0.isMuted && $0.hasBelled }
    }

    /// The TTY `offset` places from the selected one in `stepOrder`, or nil if
    /// that is past either end. If the selected TTY is a system TTY that
    /// `stepOrder` leaves out, stepping forward gives the first user TTY,
    /// because the user TTYs come after the system ones, and stepping back
    /// gives nil.
    func neighbor(by offset: Int) -> TTY? {
        let order = stepOrder
        guard let index = order.firstIndex(where: { $0 === selected }) else {
            return offset > 0 ? order.first : nil
        }
        guard order.indices.contains(index + offset) else { return nil }
        return order[index + offset]
    }
}

/// Gives a terminal `frame`, and makes it adopt the new size immediately.
///
/// UIKit lays out only the views in a window, and every terminal but the
/// selected one is outside the window. Without an explicit layout, those
/// terminals would keep their old rows and columns until shown, so their
/// thumbnails would be drawn at the wrong size and the far end would learn the
/// new size late.
private func fit(_ view: TctiTermView?, to frame: CGRect) {
    // A window's frame is empty until its view controller sets it, and a terminal made that small
    // would rewrap its scrollback to fit.
    guard let view, !frame.isEmpty else { return }
    // Set by bounds and center rather than frame, because a terminal sliding in or out during a
    // switch has a translation transform, and a view's frame is undefined under a transform.
    view.bounds.size = frame.size
    view.center = CGPoint(x: frame.midX, y: frame.midY)
    if view.window == nil {
        view.layoutIfNeeded()
    }
}

// MARK: - The TTYs

/// Holds every TTY and every window. Use it only from the main thread.
///
/// The list of TTYs, their pins, names and settings, and each window's TTYs,
/// their order and its selection are saved whenever they change and restored at
/// launch. What the terminals show is not saved. The names Settings gives
/// consoles, and whether it shows the system TTYs, are saved as separate
/// settings.
final class TTYs {

    static let shared = TTYs()

    /// Posted when TTYs are added or closed, or are reordered, renamed, pinned,
    /// unpinned or muted, or have their settings changed, and when the system
    /// TTYs the switcher shows change.
    static let didChange = Notification.Name("io.ara.tctish.ttysDidChange")

    /// Posted when a window selects a different TTY. The notification's object
    /// is the window, and its `previousKey` entry is the TTY that was selected
    /// before.
    static let selectionDidChange = Notification.Name("io.ara.tctish.ttysSelectionDidChange")
    static let previousKey = "previous"

    /// Posted when a TTY's status changes, with the TTY as the object.
    static let statusDidChange = Notification.Name("io.ara.tctish.ttysStatusDidChange")

    /// Posted when the programs on a closed TTY's console couldn't be ended,
    /// with a message saying so as the object.
    static let couldNotEndPrograms = Notification.Name("io.ara.tctish.ttysCouldNotEndPrograms")

    /// Posted when a window closes, for whatever reason, with the window as the
    /// object. `AppDelegate` then destroys its scene session, if it has one.
    static let windowDidClose = Notification.Name("io.ara.tctish.ttysWindowDidClose")

    /// The system TTYs: Kernel Log, then VM Management.
    let system: [TTY]

    /// The windows, in the order they were made. There is always at least one.
    private(set) var windows: [TTYWindow]

    private var haptics: UINotificationFeedbackGenerator?

    /// The consoles whose programs end once Linux is up, and the observer
    /// waiting for it.
    private var endingOnceUp: [Int] = []
    private var upObserver: NSObjectProtocol?

    private init() {
        let saved = Self.load()

        func restored(_ kind: TTY.Kind) -> TTY {
            let record = saved?.ttys.first { $0.kind == kind }
            return TTY(
                id: record?.id ?? UUID(), kind: kind, isMuted: record?.isMuted ?? false,
                fontSize: record?.fontSize, scrollback: record?.scrollback)
        }
        let system = [restored(.kernelLog), restored(.vmManagement)]

        // Drop saved user TTYs that are no longer valid: a console number that is out of range or
        // already taken, or any TTY past the limit.
        var numbers = Set<Int>()
        var users: [TTY] = []
        for record in saved?.ttys ?? [] {
            guard case .user(let number) = record.kind, (0..<TTY.userLimit).contains(number),
                numbers.insert(number).inserted, users.count < TTY.userLimit
            else { continue }
            users.append(
                TTY(
                    id: record.id, kind: record.kind, customName: record.customName,
                    isPinned: record.isPinned, isMuted: record.isMuted,
                    fontSize: record.fontSize, scrollback: record.scrollback))
        }

        // Each window's TTYs. What was saved before there were windows becomes one window, holding
        // every TTY in the order saved, and with nothing saved there is one window, with the system
        // TTYs Settings shows and a TTY on hvc0.
        struct Layout {
            var id: String?
            var system: [TTY]
            var users: [TTY]
            var selected: UUID?
        }
        var layouts: [Layout]
        if let saved {
            // A TTY is in the first window that lists it, and a system TTY that Settings hides is
            // in none.
            let known = system + users
            var placed = Set<UUID>()
            let records =
                saved.windows
                ?? [WindowRecord(id: nil, ttys: saved.ttys.map(\.id), selected: saved.selected)]
            layouts = records.map { record in
                let ttys = record.ttys.compactMap { id in known.first { $0.id == id } }
                    .filter { placed.insert($0.id).inserted }
                return Layout(
                    id: record.id,
                    system: system.filter { tty in
                        Self.isShown(tty.kind) && ttys.contains { $0 === tty }
                    },
                    users: ttys.filter { !$0.isSystem }, selected: record.selected)
            }

            // A user TTY that no window lists goes in the first.
            let unplaced = users.filter { !placed.contains($0.id) }
            if !unplaced.isEmpty {
                if layouts.isEmpty {
                    layouts = [Layout(system: [], users: [])]
                }
                layouts[0].users += unplaced
            }
        } else {
            users = [TTY(kind: .user(0))]
            numbers = [0]
            layouts = [Layout(system: system.filter { Self.isShown($0.kind) }, users: users)]
        }

        // Every window needs a TTY to select, so one left with none gets a new TTY on the
        // lowest-numbered free console. If none is free, every console is in another window, and
        // the empty one goes.
        for index in layouts.indices.reversed()
        where layouts[index].system.isEmpty && layouts[index].users.isEmpty {
            if let number = Self.freeConsole(taken: numbers) {
                numbers.insert(number)
                layouts[index].users = [TTY(kind: .user(number))]
            } else {
                layouts.remove(at: index)
            }
        }
        if layouts.isEmpty, let number = Self.freeConsole(taken: numbers) {
            layouts = [Layout(system: [], users: [TTY(kind: .user(number))])]
        }

        self.system = system
        windows = layouts.map { layout in
            let users = layout.users.filter(\.isPinned) + layout.users.filter { !$0.isPinned }
            let selected =
                (layout.system + users).first { $0.id == layout.selected } ?? users.first
                ?? layout.system.last ?? system[1]
            return TTYWindow(id: layout.id, system: layout.system, users: users, selected: selected)
        }
    }

    // MARK: Looking

    /// Every user TTY, window by window.
    var users: [TTY] { windows.flatMap(\.users) }

    var all: [TTY] { system + users }

    func tty(_ id: UUID) -> TTY? {
        all.first { $0.id == id }
    }

    /// The open TTY that shows a device, by its name in Linux (`hvc3`, or
    /// `ttyS0` for Kernel Log), or nil if no open TTY shows it.
    func tty(onDevice device: String) -> TTY? {
        if device == "ttyS0" {
            return system.first { $0.kind == .kernelLog }
        }
        return users.first { $0.device == device }
    }

    /// The window `tty` is in, or nil for a system TTY in none.
    func window(of tty: TTY) -> TTYWindow? {
        windows.first { $0.contains(tty) }
    }

    /// Whether `tty` is selected in its window, and so on screen.
    func isSelected(_ tty: TTY) -> Bool {
        window(of: tty)?.selected === tty
    }

    /// Whether another user TTY can be added.
    var canAdd: Bool { users.count < TTY.userLimit }

    /// What to say when another user TTY is asked for but can't be added.
    static let limitMessage = "At most \(TTY.userLimit) terminals can be open"

    /// The pill that says so.
    static let limitPill = StatusPresenter.Item(
        key: "tty-limit", message: limitMessage, state: .symbol("exclamationmark.circle"),
        duration: 3)

    /// The TTY that shows `hvc0`, the first console, or nil if it is closed.
    var hvc0: TTY? { users.first { $0.number == 0 } }

    /// The lowest-numbered console not in `taken`, or nil if every one is
    /// taken.
    private static func freeConsole(taken: Set<Int>) -> Int? {
        (0..<TTY.userLimit).first { !taken.contains($0) }
    }

    // MARK: Windows

    /// The window for the scene session `id`, as its scene connects: the one
    /// saved for it, or one it takes over, or nil if it is a new window.
    ///
    /// A session takes over a window that no session has yet, as the one made
    /// from what was saved before there were windows. It also takes over the
    /// first window when no window's session is among `openSessions`, the IDs
    /// of the sessions iOS still has.
    func window(forSession id: String, openSessions: Set<String>) -> TTYWindow? {
        if let window = windows.first(where: { $0.id == id }) {
            return window
        }
        let orphaned = windows.allSatisfy { window in
            window.id.map { !openSessions.contains($0) } ?? true
        }
        guard let window = windows.first(where: { $0.id == nil }) ?? (orphaned ? windows[0] : nil)
        else { return nil }
        window.id = id
        save()
        return window
    }

    /// Makes a window for the scene session `id`, with a new TTY, for New
    /// Window. Nil if no TTY can be added.
    func newWindow(forSession id: String) -> TTYWindow? {
        guard canAdd, let number = Self.freeConsole(taken: Set(users.compactMap(\.number))) else {
            return nil
        }
        let tty = TTY(kind: .user(number))
        let window = TTYWindow(id: id, system: [], users: [tty], selected: tty)
        windows.append(window)
        makeTerminal(for: tty, frame: windows[0].terminalFrame)
        changed()
        return window
    }

    /// Makes a window for the scene session `id` to hold `tty`, which moves
    /// there from the window it's in, for Move Terminal to New Window or a card
    /// dragged out of the switcher. Nil if `tty` can't move: it has closed, or
    /// it's a system TTY that Settings hides.
    func newWindow(forSession id: String, moving tty: TTY) -> TTYWindow? {
        guard canMove(tty) else { return nil }

        // Until its view controller sizes it, the window keeps the terminal at the size it had.
        let frame = (window(of: tty) ?? windows[0]).terminalFrame
        let emptied = takeOut(tty)
        let window = TTYWindow(id: id, system: [], users: [], selected: tty)
        window.terminalFrame = frame
        place(tty, in: window, at: nil)
        windows.append(window)

        // Its view controller puts it on screen as its view loads.
        tty.view?.removeFromSuperview()
        changed()
        if let emptied {
            NotificationCenter.default.post(name: Self.windowDidClose, object: emptied)
        }
        return window
    }

    /// Closes a window: its user TTYs close, ending what runs on their consoles
    /// if `endingPrograms`, and its system TTYs are in no window until shown
    /// again. The last window doesn't close, but loses its session, for the
    /// next scene to take over. The scene session is destroyed too, unless
    /// `keepingSession`.
    func closeWindow(_ window: TTYWindow, endingPrograms: Bool, keepingSession: Bool = false) {
        guard windows.contains(where: { $0 === window }) else { return }
        guard windows.count > 1 else {
            window.id = nil
            save()
            return
        }

        windows.removeAll { $0 === window }
        if keepingSession {
            // With no session, `AppDelegate` has none to destroy as the window closes.
            window.id = nil
        }
        let closing = window.users
        window.system = []
        window.users = []
        tearDown(closing)
        changed()
        NotificationCenter.default.post(name: Self.windowDidClose, object: window)

        if endingPrograms {
            endPrograms(onConsoles: closing.compactMap(\.number))
        }
    }

    /// Closes the window of a scene session that iOS discarded, as when it is
    /// closed from App Exposé, following Keep Programs Running When Closing a
    /// Window.
    func windowDiscarded(session id: String) {
        guard let window = windows.first(where: { $0.id == id }) else { return }
        closeWindow(window, endingPrograms: !AppSetting.keepProgramsWhenClosingWindow.bool)
    }

    /// Whether `tty` can move to another window: it's open, and if it's a
    /// system TTY, Settings shows it.
    func canMove(_ tty: TTY) -> Bool {
        tty.isSystem ? Self.isShown(tty.kind) : window(of: tty) != nil
    }

    /// Moves `tty` to `target` from the window it's in, if any, and selects it
    /// there if `selecting`. A user TTY goes among `target`'s pinned TTYs or
    /// its cards, as it is, at `index` among them, or else last. A system TTY
    /// goes in its place before them. A window that this leaves with no TTY
    /// closes.
    func move(_ tty: TTY, to target: TTYWindow, at index: Int? = nil, selecting: Bool = true) {
        guard canMove(tty), windows.contains(where: { $0 === target }) else { return }
        guard !target.contains(tty) else {
            if selecting {
                select(tty)
            }
            return
        }

        let emptied = takeOut(tty)
        place(tty, in: target, at: index)

        // Selecting it puts it on screen here. Otherwise it's taken off screen: the window it left
        // did that already as it selected another TTY, but not if that window closed.
        if !selecting {
            tty.view?.removeFromSuperview()
        }
        changed()
        if let emptied {
            NotificationCenter.default.post(name: Self.windowDidClose, object: emptied)
        }
        if selecting {
            select(tty)
        }
    }

    /// Moves every TTY in the other windows to `target`, after those it has,
    /// for Merge All Windows, and closes those windows. `target` keeps its
    /// selection.
    func merge(into target: TTYWindow) {
        let others = windows.filter { $0 !== target }
        guard !others.isEmpty, windows.contains(where: { $0 === target }) else { return }

        windows = [target]
        for window in others {
            for tty in window.ordered {
                place(tty, in: target, at: nil)
                tty.view?.removeFromSuperview()
            }
            window.system = []
            window.users = []
        }
        changed()
        for window in others {
            NotificationCenter.default.post(name: Self.windowDidClose, object: window)
        }
    }

    /// Takes `tty` out of the window it's in, as it moves to another. If it was
    /// selected there, the window selects the user TTY after it instead, or
    /// failing that the one before it, or failing that a system TTY. Returns
    /// the window if that leaves it with no TTY: it is then no longer among
    /// `windows`, and once `tty` is in its new window, the caller posts
    /// `windowDidClose` for it.
    private func takeOut(_ tty: TTY) -> TTYWindow? {
        guard let holder = window(of: tty) else { return nil }
        let wasSelected = holder.selected === tty
        let users = holder.users

        holder.system.removeAll { $0 === tty }
        holder.users.removeAll { $0 === tty }
        guard !holder.ordered.isEmpty else {
            windows.removeAll { $0 === holder }
            return holder
        }

        if wasSelected {
            let index = users.firstIndex { $0 === tty }
            let next =
                index.flatMap { index in users[(index + 1)...].first ?? users[..<index].last }
                ?? holder.users.first ?? holder.system.last
            next.map(select)
        }
        return nil
    }

    /// Puts `tty`, which is in no window, in `window`, at `index` among the
    /// window's pinned TTYs or its cards, as `move` does, and gives it the
    /// window's size.
    private func place(_ tty: TTY, in window: TTYWindow, at index: Int?) {
        if tty.isSystem {
            window.system = system.filter { kept in
                kept === tty || window.system.contains { $0 === kept }
            }
        } else {
            var section = tty.isPinned ? window.pinned : window.cards
            section.insert(tty, at: min(max(index ?? section.count, 0), section.count))
            window.users = tty.isPinned ? section + window.cards : window.pinned + section
        }
        fit(tty.view, to: window.terminalFrame)
        tty.outputCount &+= 1
    }

    // MARK: Terminals

    /// Makes a terminal view, at `frame`, for every TTY that lacks one, and
    /// gives `window`'s terminals that frame. A view controller calls this
    /// once, as it loads.
    func makeTerminals(in window: TTYWindow, frame: CGRect) {
        window.terminalFrame = frame
        for tty in all where tty.view == nil {
            makeTerminal(for: tty, frame: frame)
        }
    }

    private func makeTerminal(for tty: TTY, frame: CGRect) {
        let view = TctiTermView(frame: frame)
        fit(view, to: frame)
        view.fontSizeOverride = tty.fontSize
        view.scrollbackOverride = tty.scrollback

        view.onOutput = { [weak self, weak tty] in
            guard let self, let tty else { return }
            noteOutput(on: tty)
        }
        view.onBell = { [weak self, weak tty] in
            guard let self, let tty else { return }
            noteBell(on: tty)
        }

        tty.view = view

        switch tty.kind {
        case .kernelLog:
            view.transport = ChardevTransport.kernelLog
        case .vmManagement:
            view.transport = ChardevTransport.vmManagement
        case .user(let number):
            view.transport = ConsoleTransport.consoles[number]
        }
    }

    // MARK: Status

    /// Whether a TTY's status is kept. A system TTY that Settings hides keeps
    /// none, so that showing it again doesn't bring back what happened while it
    /// was hidden.
    private func keepsStatus(_ tty: TTY) -> Bool {
        !tty.isSystem || Self.isShown(tty.kind)
    }

    private func noteOutput(on tty: TTY) {
        tty.outputCount &+= 1

        guard !isSelected(tty), !tty.hasUnseenOutput, keepsStatus(tty) else { return }
        tty.hasUnseenOutput = true
        postStatus(of: tty)
    }

    private func noteBell(on tty: TTY) {
        guard !tty.isMuted, keepsStatus(tty) else { return }

        // A selected TTY is on screen, so its bell gets the haptic tap that SwiftTerm's default
        // bell handler gives, rather than a status icon.
        guard !isSelected(tty) else {
            if haptics == nil {
                haptics = UINotificationFeedbackGenerator()
            }
            haptics?.notificationOccurred(.warning)
            return
        }

        guard !tty.hasBelled else { return }
        tty.hasBelled = true
        postStatus(of: tty)
    }

    private func postStatus(of tty: TTY) {
        NotificationCenter.default.post(name: Self.statusDidChange, object: tty)
    }

    // MARK: Changing

    /// Makes `tty` the selected TTY in its window, which the window's view
    /// controller then shows. Selecting a TTY counts as seeing it, so its bell
    /// and unseen-output status are cleared.
    func select(_ tty: TTY) {
        guard let window = window(of: tty), tty !== window.selected else { return }

        let previous = window.selected
        window.selected = tty

        if tty.hasBelled || tty.hasUnseenOutput {
            tty.hasBelled = false
            tty.hasUnseenOutput = false
            postStatus(of: tty)
        }

        save()
        NotificationCenter.default.post(
            name: Self.selectionDidChange, object: window, userInfo: [Self.previousKey: previous])
    }

    /// Adds a user TTY on the lowest-numbered free console, as `window`'s last
    /// card. Returns nil if there are already `TTY.userLimit` user TTYs.
    @discardableResult
    func add(to window: TTYWindow) -> TTY? {
        // Not to a window that has closed, which a TTY could never be shown in or reached from.
        guard canAdd, windows.contains(where: { $0 === window }),
            let number = Self.freeConsole(taken: Set(users.compactMap(\.number)))
        else { return nil }

        let tty = TTY(kind: .user(number))
        window.users.append(tty)
        makeTerminal(for: tty, frame: window.terminalFrame)
        changed()
        return tty
    }

    /// Closes a user TTY. If it was selected, the user TTY after it in its
    /// window is selected instead, or failing that the one before it, or
    /// failing that what `fallback(in:)` gives.
    ///
    /// What runs on the TTY's console keeps running, for when a TTY opens on it
    /// again, unless `endingPrograms`.
    func close(_ tty: TTY, endingPrograms: Bool = false) {
        close([tty], endingPrograms: endingPrograms)
    }

    /// Closes every unpinned user TTY in `tty`'s window except `tty`, ending
    /// what runs on their consoles if `endingPrograms`.
    func closeAll(but tty: TTY, endingPrograms: Bool = false) {
        close(othersClosed(by: tty), endingPrograms: endingPrograms)
    }

    /// The TTYs that `closeAll(but:)` would close, for the Close All But This
    /// menu item.
    func othersClosed(by tty: TTY) -> [TTY] {
        window(of: tty)?.users.filter { $0 !== tty && !$0.isPinned } ?? []
    }

    private func close(_ closing: [TTY], endingPrograms: Bool) {
        let closing = closing.filter { !$0.isSystem && window(of: $0) != nil }
        guard !closing.isEmpty else { return }
        let isClosing = { (tty: TTY) in closing.contains { $0 === tty } }

        // A window left with no TTY closes, as long as another stays open.
        var emptied: [TTYWindow] = []

        for window in windows where window.users.contains(where: isClosing) {
            // If the selected TTY is closing, choose the new selection before removing anything,
            // from the current order: the first TTY after it that stays open, or failing that the
            // nearest one before it that stays.
            let selectedCloses = isClosing(window.selected)
            var next: TTY?
            if selectedCloses,
                let index = window.users.firstIndex(where: { $0 === window.selected })
            {
                next =
                    window.users[(index + 1)...].first { !isClosing($0) }
                    ?? window.users[..<index].last { !isClosing($0) }
            }

            window.users.removeAll(where: isClosing)
            if window.ordered.isEmpty, windows.count - emptied.count > 1 {
                emptied.append(window)
            } else if selectedCloses {
                select(next ?? fallback(in: window))
            }
        }
        windows.removeAll { window in emptied.contains { $0 === window } }

        // Tear down the closed terminals last, once the selection has moved off any of them that
        // was on screen. Ending what runs on them, if asked, comes after.
        tearDown(closing)
        changed()
        for window in emptied {
            NotificationCenter.default.post(name: Self.windowDidClose, object: window)
        }

        if endingPrograms {
            endPrograms(onConsoles: closing.compactMap(\.number))
        }
    }
    /// Takes closed TTYs' terminals off screen and detaches them from their
    /// consoles, which disconnects the app from them and leaves what runs on
    /// them running.
    private func tearDown(_ closed: [TTY]) {
        for tty in closed {
            tty.view?.transport = nil
            tty.view?.removeFromSuperview()
            // SwiftTerm's display link retains the view, so the view isn't freed until
            // `updateUiClosed()` invalidates the link.
            tty.view?.updateUiClosed()
        }
    }

    /// Has the guest agent hang up the consoles `hvc<number>`, which ends the
    /// programs on them, and has the next login on each wait for a TTY to show
    /// it. One request for them all, so that they share one wait, rather than
    /// holding up later requests a second per console.
    private func endPrograms(onConsoles numbers: [Int]) {
        guard !numbers.isEmpty else { return }

        // A window closed while tctiSH wasn't running is closed at the next launch, before Linux is
        // up to be asked.
        guard GuestAgent.shared.isUp else {
            endingOnceUp += numbers
            guard upObserver == nil else { return }
            upObserver = NotificationCenter.default.addObserver(
                forName: GuestAgent.linuxDidComeUp, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                upObserver.map(NotificationCenter.default.removeObserver)
                upObserver = nil
                let numbers = endingOnceUp
                endingOnceUp = []
                endPrograms(onConsoles: numbers)
            }
            return
        }

        let devices = numbers.map { "hvc\($0)" }
        let named = ListFormatter.localizedString(byJoining: devices)
        GuestAgent.shared.request("hangup", arguments: devices) { answer in
            switch answer {
            case .done(let counts):
                Log.ui.note("ttys: hung up \(named): \(counts.joined(separator: " "))")

                // A TTY may have opened on one of the consoles since it closed, as when closing the
                // last TTY opens a new one. It said it showed the console before the hangup, which
                // marked the console as not shown, so it says so again for the login that waits.
                for number in numbers {
                    ConsoleTransport.consoles[number].redraw()
                }

            case .failed(let reason):
                Log.ui.warn("ttys: couldn't hang up \(named): \(reason)")

                // Linux restarting ended the programs anyway.
                guard reason != GuestAgent.restartReason else { return }
                NotificationCenter.default.post(
                    name: Self.couldNotEndPrograms,
                    object: "Couldn't end the programs on \(named): \(reason)")
            }
        }
    }

    /// Renames a user TTY. A nil name, or one that is empty once whitespace is
    /// trimmed, restores the TTY's default name.
    func rename(_ tty: TTY, to name: String?) {
        guard !tty.isSystem else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        tty.customName = trimmed?.isEmpty == false ? trimmed : nil
        changed()
    }

    func setPinned(_ tty: TTY, _ pinned: Bool) {
        guard !tty.isSystem, tty.isPinned != pinned, let window = window(of: tty) else { return }
        tty.isPinned = pinned

        // Move the TTY to the boundary between its window's pinned TTYs and its cards: a newly
        // pinned TTY becomes the last pinned one, and a newly unpinned TTY becomes the first card.
        window.users.removeAll { $0 === tty }
        let firstCard = window.users.firstIndex { !$0.isPinned } ?? window.users.endIndex
        window.users.insert(tty, at: firstCard)
        changed()
    }

    func setMuted(_ tty: TTY, _ muted: Bool) {
        tty.isMuted = muted
        if muted {
            tty.hasBelled = false
        }
        postStatus(of: tty)
        changed()
    }

    func setFontSize(_ tty: TTY, _ size: Int?) {
        tty.fontSize = size
        tty.outputCount &+= 1
        changed()
    }

    func setScrollback(_ tty: TTY, _ lines: Int?) {
        tty.scrollback = lines
        changed()
    }

    /// Shows or hides a system TTY in the switcher, and saves the choice.
    /// Showing one puts it in `window`, or the first window if that is nil.
    /// Hiding one takes it out of its window and clears its status. If it was
    /// selected there, the window's first user TTY is selected instead, or
    /// failing that what `fallback(in:)` gives. A window it leaves with no TTY
    /// closes, unless it's the only one.
    func setShown(_ kind: TTY.Kind, _ shown: Bool, in window: TTYWindow? = nil) {
        guard let setting = Self.shownSetting(kind),
            let tty = system.first(where: { $0.kind == kind })
        else { return }
        setting.set(shown)

        var emptied: TTYWindow?
        if shown, self.window(of: tty) == nil {
            let window = window ?? windows[0]
            window.system = system.filter { kept in
                kept === tty || window.system.contains { $0 === kept }
            }
            fit(tty.view, to: window.terminalFrame)
            tty.outputCount &+= 1
        } else if !shown, let window = self.window(of: tty) {
            window.system.removeAll { $0 === tty }
            if window.ordered.isEmpty, windows.count > 1 {
                windows.removeAll { $0 === window }
                emptied = window
            } else if window.selected === tty {
                select(window.users.first ?? fallback(in: window))
            }
            if tty.hasBelled || tty.hasUnseenOutput {
                tty.hasBelled = false
                tty.hasUnseenOutput = false
                postStatus(of: tty)
            }
        }
        changed()
        if let emptied {
            NotificationCenter.default.post(name: Self.windowDidClose, object: emptied)
        }
    }

    /// What `window` selects when its selected TTY goes and it has no user TTY
    /// to take its place: VM Management, or failing that Kernel Log, if it's in
    /// the window, or else a new TTY.
    private func fallback(in window: TTYWindow) -> TTY {
        if let shown = window.system.last {
            return shown
        }
        if let added = add(to: window) {
            return added
        }
        // A fallback is wanted only once the window has no user TTY, and the window is the only
        // one, so one can always be added.
        assertionFailure("ttys: nothing to fall back on")
        return system[1]
    }

    /// Gives a console, by its name in Linux, the name its TTYs go by until
    /// they are renamed. A nil name, or one that is empty once whitespace is
    /// trimmed, goes back to the console's name.
    func setDefaultName(_ name: String?, ofConsole device: String) {
        var names = AppSetting.ttyDefaultNames.stringsByKey
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        names[device] = trimmed?.isEmpty == false ? trimmed : nil
        AppSetting.ttyDefaultNames.set(names)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The name Settings gives a console, by its name in Linux, or nil if it
    /// gives none.
    static func defaultName(ofConsole device: String) -> String? {
        AppSetting.ttyDefaultNames.stringsByKey[device]
    }

    /// Whether Settings says to show a system TTY in the switcher. Always true
    /// for a user TTY.
    static func isShown(_ kind: TTY.Kind) -> Bool {
        shownSetting(kind)?.bool ?? true
    }

    private static func shownSetting(_ kind: TTY.Kind) -> AppSetting? {
        switch kind {
        case .kernelLog: .showKernelLog
        case .vmManagement: .showVmManagement
        case .user: nil
        }
    }

    /// Puts a window's pinned TTYs, or its cards, in the order of `ids`, which
    /// must list exactly the TTYs of one of the two.
    func reorder(_ ids: [UUID]) {
        let moved = ids.compactMap(tty)
        guard let first = moved.first, !first.isSystem, let window = window(of: first) else {
            return
        }

        // Accept `ids` only if it lists exactly the pinned TTYs or exactly the cards, and ignore it
        // otherwise. An order taken from a list that has since changed could drop TTYs it doesn't
        // list, or repeat TTYs that moved to the other group or another window.
        let section = first.isPinned ? window.pinned : window.cards
        guard moved.count == section.count,
            Set(moved.map(\.id)) == Set(section.map(\.id))
        else { return }

        if first.isPinned {
            window.users = moved + window.cards
        } else {
            window.users = window.pinned + moved
        }
        changed()
    }

    private func changed() {
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Saving

    private struct Record: Codable {
        var id: UUID
        var kind: TTY.Kind
        var customName: String?
        var isPinned: Bool
        var isMuted: Bool
        var fontSize: Int?
        var scrollback: Int?
    }

    /// A window: its scene session, its TTYs in switcher order, and its
    /// selection.
    private struct WindowRecord: Codable {
        var id: String?
        var ttys: [UUID]
        var selected: UUID?
    }

    private struct Saved: Codable {
        var ttys: [Record]

        /// Nil in what was saved before there were windows. Every TTY was then
        /// in the one window, in the order of `ttys`, and `selected` was its
        /// selection.
        var windows: [WindowRecord]?
        var selected: UUID?
    }

    private func save() {
        let saved = Saved(
            ttys: all.map {
                Record(
                    id: $0.id, kind: $0.kind, customName: $0.customName, isPinned: $0.isPinned,
                    isMuted: $0.isMuted, fontSize: $0.fontSize, scrollback: $0.scrollback)
            },
            windows: windows.map {
                WindowRecord(id: $0.id, ttys: $0.ordered.map(\.id), selected: $0.selected.id)
            })

        do {
            AppSetting.ttys.set(try JSONEncoder().encode(saved))
        } catch {
            Log.ui.warn("ttys: couldn't save: \(error)")
        }
    }

    private static func load() -> Saved? {
        guard let data = AppSetting.ttys.data else { return nil }
        do {
            return try JSONDecoder().decode(Saved.self, from: data)
        } catch {
            Log.ui.warn("ttys: couldn't read what was saved, starting afresh: \(error)")
            return nil
        }
    }
}
