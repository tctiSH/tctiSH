//
//  TTYs.swift
//  The TTYs the switcher shows, and which one is selected and on screen.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

// MARK: - A TTY

/// One of the terminals the switcher shows.
///
/// Two belong to the system and always exist: the kernel log and QEMU's
/// monitor. The rest belong to the user, at most `userLimit` of them, and each
/// is named for its console device in Linux (`hvc0`, `hvc1`, and so on).
final class TTY {

    enum Kind: Codable, Hashable {
        case kernelLog
        case vmManagement
        case user(Int)
    }

    /// The maximum number of user TTYs.
    static let userLimit = 12

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

    /// The name shown for the TTY: the user's name for it if it has been
    /// renamed, and its default name otherwise.
    var name: String { customName ?? defaultName }

    var defaultName: String {
        switch kind {
        case .kernelLog: "Kernel Log"
        case .vmManagement: "VM Management"
        case .user(let number): "hvc\(number)"
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

// MARK: - The TTYs

/// Holds every TTY, their order, and which one is selected. Use it only from
/// the main thread.
///
/// The list of TTYs, their order, pins, names and settings, and the selection
/// are saved whenever they change and restored at launch. What the terminals
/// show is not saved.
final class TTYs {

    static let shared = TTYs()

    /// Posted when TTYs are added or closed, or are reordered, renamed, pinned,
    /// unpinned or muted, or have their settings changed.
    static let didChange = Notification.Name("io.ara.tctish.ttysDidChange")

    /// Posted when a different TTY is selected. The notification's object is
    /// the TTY that was selected before.
    static let selectionDidChange = Notification.Name("io.ara.tctish.ttysSelectionDidChange")

    /// Posted when a TTY's status changes, with the TTY as the object.
    static let statusDidChange = Notification.Name("io.ara.tctish.ttysStatusDidChange")

    /// The system TTYs: Kernel Log, then VM Management.
    let system: [TTY]

    /// The user's TTYs in switcher order: the pinned ones first, then the rest.
    private(set) var users: [TTY]

    private(set) var selected: TTY

    private var haptics: UINotificationFeedbackGenerator?

    /// The frame every terminal is given, set by the view controller. Every
    /// terminal is kept at this size, shown or not, so that each is ready to be
    /// shown and its thumbnail has the shape of the screen. A change counts
    /// toward every TTY's `outputCount`, so that the cards redraw their
    /// thumbnails.
    var terminalFrame: CGRect = .zero {
        didSet {
            guard terminalFrame != oldValue else { return }
            for tty in all {
                fit(tty.view)
                tty.outputCount &+= 1
            }
        }
    }

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
        if saved == nil {
            users = [TTY(kind: .user(0))]
        }
        users = users.filter(\.isPinned) + users.filter { !$0.isPinned }

        self.system = system
        self.users = users
        selected = (system + users).first { $0.id == saved?.selected } ?? users.first ?? system[1]
    }

    // MARK: Looking

    var all: [TTY] { system + users }

    /// The user's pinned TTYs, and the unpinned ones, which the switcher shows
    /// as cards.
    var pinned: [TTY] { users.filter(\.isPinned) }
    var cards: [TTY] { users.filter { !$0.isPinned } }

    /// Every TTY in switcher order: the system TTYs, then the pinned ones, then
    /// the cards.
    var ordered: [TTY] { system + users }

    /// The TTYs that swiping across the switcher button and the keyboard
    /// shortcuts step through: the user TTYs, preceded by the system TTYs if
    /// that option is on in Settings.
    var stepOrder: [TTY] {
        AppSetting.stepThroughSystemTTYs.bool ? ordered : users
    }

    func tty(_ id: UUID) -> TTY? {
        all.first { $0.id == id }
    }

    /// Whether another user TTY can be added.
    var canAdd: Bool { users.count < TTY.userLimit }

    /// The TTY that shows `hvc0`, the console Linux's login is on, or nil if it
    /// is closed.
    var hvc0: TTY? { users.first { $0.number == 0 } }

    /// Whether any TTY other than the selected one has rung the bell while
    /// unmuted and has not been selected since.
    var needsAttention: Bool {
        all.contains { $0 !== selected && !$0.isMuted && $0.hasBelled }
    }

    // MARK: Terminals

    /// Makes a terminal view, at `frame`, for every TTY that lacks one. The
    /// view controller calls this once, as it loads.
    func makeTerminals(frame: CGRect) {
        terminalFrame = frame
        for tty in all where tty.view == nil {
            makeTerminal(for: tty)
        }
    }

    /// Gives a terminal `terminalFrame`, and makes it adopt the new size
    /// immediately.
    ///
    /// UIKit lays out only the views in a window, and every terminal but the
    /// selected one is outside the window. Without an explicit layout, those
    /// terminals would keep their old rows and columns until shown, so their
    /// thumbnails would be drawn at the wrong size and the far end would learn
    /// the new size late.
    private func fit(_ view: TctiTermView?) {
        guard let view else { return }
        // Set by bounds and center rather than frame, because a terminal sliding in or out during a
        // switch has a translation transform, and a view's frame is undefined under a transform.
        view.bounds.size = terminalFrame.size
        view.center = CGPoint(x: terminalFrame.midX, y: terminalFrame.midY)
        if view.window == nil {
            view.layoutIfNeeded()
        }
    }

    private func makeTerminal(for tty: TTY) {
        let view = TctiTermView(frame: terminalFrame)
        fit(view)
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

        guard tty.number != 0 else {
            view.transport = ConsoleTransport.shared
            return
        }

        view.transport = EchoTransport()

        let about =
            switch tty.kind {
            case .kernelLog: "The kernel's log will be here once it is connected."
            case .vmManagement: "QEMU's monitor will be here once it is connected."
            case .user: "\(tty.defaultName) isn't connected to Linux yet."
            }
        view.feed(text: "\u{1b}[2m\(about) Until then, it echoes what you type.\u{1b}[0m\r\n")
    }

    // MARK: Status

    private func noteOutput(on tty: TTY) {
        tty.outputCount &+= 1

        guard tty !== selected, !tty.hasUnseenOutput else { return }
        tty.hasUnseenOutput = true
        postStatus(of: tty)
    }

    private func noteBell(on tty: TTY) {
        guard !tty.isMuted else { return }

        // The selected TTY is on screen, so its bell gets the haptic tap that SwiftTerm's default
        // bell handler gives, rather than a status icon.
        guard tty !== selected else {
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

    /// Makes `tty` the selected TTY, which the view controller then shows.
    /// Selecting a TTY counts as seeing it, so its bell and unseen-output
    /// status are cleared.
    func select(_ tty: TTY) {
        guard tty !== selected, all.contains(where: { $0 === tty }) else { return }

        let previous = selected
        selected = tty

        if tty.hasBelled || tty.hasUnseenOutput {
            tty.hasBelled = false
            tty.hasUnseenOutput = false
            postStatus(of: tty)
        }

        save()
        NotificationCenter.default.post(name: Self.selectionDidChange, object: previous)
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

    /// Adds a user TTY on the lowest-numbered free console, as the last card.
    /// Returns nil if there are already `TTY.userLimit` user TTYs.
    @discardableResult
    func add() -> TTY? {
        guard canAdd else { return nil }

        let taken = Set(users.compactMap(\.number))
        guard let number = (0..<TTY.userLimit).first(where: { !taken.contains($0) }) else {
            return nil
        }

        let tty = TTY(kind: .user(number))
        users.append(tty)
        makeTerminal(for: tty)
        changed()
        return tty
    }

    /// Closes a user TTY. If it was selected, the user TTY after it is selected
    /// instead, or failing that the one before it, or VM Management if it was
    /// the only user TTY.
    func close(_ tty: TTY) {
        close([tty])
    }

    /// Closes every unpinned user TTY except `tty`.
    func closeAll(but tty: TTY) {
        close(users.filter { $0 !== tty && !$0.isPinned })
    }

    /// The TTYs that `closeAll(but:)` would close, for the Close All But This
    /// menu item.
    func othersClosed(by tty: TTY) -> [TTY] {
        users.filter { $0 !== tty && !$0.isPinned }
    }

    private func close(_ closing: [TTY]) {
        let closing = closing.filter { tty in !tty.isSystem && users.contains { $0 === tty } }
        guard !closing.isEmpty else { return }

        // If the selected TTY is closing, choose the new selection before removing anything, from
        // the current order: the first TTY after it that stays open, or failing that the nearest
        // one before it that stays, or failing that VM Management.
        var next: TTY?
        if closing.contains(where: { $0 === selected }),
            let index = users.firstIndex(where: { $0 === selected })
        {
            let staying = { (tty: TTY) in !closing.contains { $0 === tty } }
            next =
                users[(index + 1)...].first(where: staying)
                ?? users[..<index].last(where: staying)
                ?? system[1]
        }

        users.removeAll { tty in closing.contains { $0 === tty } }
        if let next {
            select(next)
        }

        // Tear down the closed terminals last, once the selection has moved off any of them that
        // was on screen. Detaching the `hvc0` terminal from its transport leaves the console
        // connected, and what runs on it running, for when the TTY is opened again.
        for tty in closing {
            tty.view?.transport = nil
            tty.view?.removeFromSuperview()
            // SwiftTerm's display link retains the view, so the view isn't freed until
            // `updateUiClosed()` invalidates the link.
            tty.view?.updateUiClosed()
        }
        changed()
    }

    /// Renames a user TTY. A nil name, or one that is empty once whitespace is
    /// trimmed, restores the TTY's default name, its device name.
    func rename(_ tty: TTY, to name: String?) {
        guard !tty.isSystem else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        tty.customName = trimmed?.isEmpty == false ? trimmed : nil
        changed()
    }

    func setPinned(_ tty: TTY, _ pinned: Bool) {
        guard !tty.isSystem, tty.isPinned != pinned, users.contains(where: { $0 === tty })
        else { return }
        tty.isPinned = pinned

        // Move the TTY to the boundary between the pinned TTYs and the cards: a newly pinned TTY
        // becomes the last pinned one, and a newly unpinned TTY becomes the first card.
        users.removeAll { $0 === tty }
        let firstCard = users.firstIndex { !$0.isPinned } ?? users.endIndex
        users.insert(tty, at: firstCard)
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

    /// Puts the pinned TTYs, or the cards, in the order of `ids`, which must
    /// list exactly the TTYs of one of the two.
    func reorder(_ ids: [UUID]) {
        let moved = ids.compactMap(tty)
        guard let first = moved.first, !first.isSystem else { return }

        // Accept `ids` only if it lists exactly the pinned TTYs or exactly the cards, and ignore it
        // otherwise. An order taken from a list that has since changed could drop TTYs it doesn't
        // list, or repeat TTYs that moved to the other group.
        let section = first.isPinned ? pinned : cards
        guard moved.count == section.count,
            Set(moved.map(\.id)) == Set(section.map(\.id))
        else { return }

        if first.isPinned {
            users = moved + cards
        } else {
            users = pinned + moved
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

    private struct Saved: Codable {
        var ttys: [Record]
        var selected: UUID?
    }

    private func save() {
        let saved = Saved(
            ttys: all.map {
                Record(
                    id: $0.id, kind: $0.kind, customName: $0.customName, isPinned: $0.isPinned,
                    isMuted: $0.isMuted, fontSize: $0.fontSize, scrollback: $0.scrollback)
            },
            selected: selected.id)

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
