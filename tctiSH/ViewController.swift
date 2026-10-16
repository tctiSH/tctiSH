//
//  tctiSH primary view controller.
//  Currently, primarily hosts our terminal.
//
//  Created by Miguel de Icaza on 3/19/19.
//  Modified for tctiSH by @ktemkin.
//
//  Copyright © 2022 Kate Temkin. All rights reserved.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import GameController
import SwiftTerm
import UIKit

class ViewController: UIViewController {

    /// The TTYs this view controller's window shows. Set by the scene delegate
    /// before the view loads.
    var ttyWindow: TTYWindow!

    /// The selected TTY's terminal, which is the one on screen.
    var terminal: TctiTermView { ttyWindow.selected.view }

    /// The padding used around the current view's frame.
    let padding: CGFloat = 7

    /// Controls the offset at which this window will render given the
    /// keyboard's presence.
    var keyboardDelta: CGFloat = 0

    /// Where the keyboard last said it was, in screen coordinates.
    private var keyboardScreenFrame: CGRect = .zero

    /// Shows the window's pills: the app's, from `AppStatus`, and those only
    /// this window shows.
    private var status: StatusPresenter?

    /// Whether the pill about ttyS0's size is up, and so follows the
    /// terminal's, in whichever window shows Kernel Log.
    private static var serialSizeShown = false

    /// Posted when the pill about ttyS0's size should be put up, updated or
    /// taken away.
    private static let serialSizeDidChange = Notification.Name("io.ara.tctish.serialSizeDidChange")

    /// The keys above the keyboard. Held here because the terminal lets go of
    /// it while a hardware keyboard has it hidden.
    private(set) var keyBar: KeyBar?

    /// The bottom of the space for the key bar's rails while they're shown: the
    /// keyboard's top edge, or the screen's bottom with a hardware one.
    private var railsBottom: CGFloat?

    /// The view controller to present app-wide alerts and sheets from: the
    /// window most recently active, while it's still in front, or else one that
    /// is, or else any. Main thread only.
    ///
    /// Its terminal is that window's selected TTY's. For whether Linux is up,
    /// ask `GuestAgent`: the selected TTY is often not `hvc0`.
    static var active: ViewController? {
        get {
            if let lastActive,
                lastActive.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
            {
                return lastActive
            }
            let scenes = UIApplication.shared.connectedScenes
            func controller(of scene: UIScene) -> ViewController? {
                (scene.delegate as? SceneDelegate)?.window?.rootViewController as? ViewController
            }
            return scenes.filter { $0.activationState == .foregroundActive }.lazy
                .compactMap(controller(of:)).first
                ?? lastActive ?? scenes.lazy.compactMap(controller(of:)).first
        }
        set { lastActive = newValue }
    }
    private static weak var lastActive: ViewController?

    /// Whatever is on top of the view controller, to present from: itself, or
    /// what it presents, or what that presents, and so on.
    var topmost: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController {
            top = next
        }
        return top
    }

    /// Whether the window has closed, while its scene goes; see
    /// `windowDidClose`.
    private var windowClosed = false

    /// The block observers this window registered, removed as it goes. A
    /// window's view controller is freed when the window closes, unlike the
    /// TTYs it watches.
    private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The TTY switcher, while it's open.
    private(set) var switcher: TTYSwitcherViewController?

    /// Whether the switcher is animating out, to be gone once it has.
    private var switcherClosing = false

    /// Whether the terminal, or the find bar over it, had the keyboard when the
    /// switcher opened, so that the terminal gets it back when the switcher
    /// closes.
    private var keyboardBeforeSwitcher = false

    /// While the switcher is open, the view size that the terminal frame was
    /// last computed for. The frame is otherwise held still under the switcher;
    /// a new size means the device turned, and the terminal is resized for it.
    private var sizeUnderSwitcher: CGSize?

    /// The find bar, while it's open, over the terminal it searches.
    private var findBar: FindBar?

    /// The switcher button that floats over the terminal while the key bar is
    /// off screen.
    private let floatingSwitcher = FloatingSwitcher()

    /// Goes back to the newest output in a terminal scrolled up from it.
    private let followButton = FollowButton()

    /// Whether the follow button is shown or fading in.
    private var followButtonShown = false

    /// The style of the bars and buttons over the terminal, and of the status
    /// bar: dark over a dark theme, light over a light one.
    private var overlayStyle = UIUserInterfaceStyle.dark

    /// The tint of the glass of the bars and buttons over the terminal.
    private var glassTint: UIColor?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        overlayStyle == .light ? .darkContent : .lightContent
    }

    /// Whether the floating switcher button is shown or fading in.
    private var floatingSwitcherShown = false

    /// Whether an update of the floating switcher button is already scheduled
    /// for the next turn of the run loop.
    private var floatingSwitcherPending = false

    /// The pill that briefly shows which TTY a step landed on.
    private var stepPill: UILabel?

    /// Builds the TTY menu shown by holding the switcher button. Its Search
    /// item selects the TTY and opens the find bar on it.
    private lazy var ttyMenu = TTYMenu(presenter: self) { [weak self] tty in
        TTYs.shared.select(tty)
        self?.openFindBar()
    }
    private var stepPillExpiry: DispatchWorkItem?

    /// Which way the terminals slide when the selection changes: +1 brings the
    /// new terminal in from the right, -1 from the left, and nil means no
    /// slide. Set only while `slide(_:_:)` changes the selection.
    private var slideDirection: Int?

    /// While terminals slide: the black backdrop behind them, a page under each
    /// terminal that moves with it (see `slidePage(for:)`), and the number of
    /// slide animations still running.
    private var slideBackdrop: UIView?
    private var slidePages: [ObjectIdentifier: UIView] = [:]
    private var slidesUnderway = 0

    /// The terminals slid off screen, removed from the view once every slide
    /// has finished.
    private var slidOut: [TctiTermView] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        // Make every TTY's terminal at the same frame, and put the selected one on screen.
        TTYs.shared.makeTerminals(in: ttyWindow, frame: makeFrame(keyboardDelta: 0))
        let currentTerminal = terminal
        view.addSubview(currentTerminal)

        // The first window is the active one until a scene says otherwise.
        if Self.active == nil {
            Self.active = self
        }

        setupKeyboardMonitor()

        // Before `becomeFirstResponder`, because the accessory view is read as the terminal takes
        // the keyboard. Installing it afterwards would briefly show SwiftTerm's bar first.
        keyBar = KeyBar.install(on: currentTerminal) { [weak self] in
            self?.openSettings(nil)
        }
        keyBar?.didMove = { [weak self] in self?.updateKeyboardDelta() }
        if let rails = keyBar?.rails {
            rails.frame = view.bounds
            view.addSubview(rails)
        }
        setUpTTYs()

        _ = currentTerminal.becomeFirstResponder()

        explainSerialSize()

        // The window's pills. The first presenter to attach also starts the app's reporting; see
        // `AppStatus.attach`.
        let status = StatusPresenter(over: view) { [weak self] in
            self?.terminal.nativeBackgroundColor ?? .black
        }
        status.keepsClearOf = followButton
        self.status = status
        AppStatus.shared.attach(status)

        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme), name: TerminalThemes.didChange, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (controller: ViewController, _) in
            controller.applyTheme()
            TerminalThemes.appearanceChanged()
        }
        // The glass's tint follows Increase Contrast and Reduce Transparency.
        for name in [
            UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            UIAccessibility.reduceTransparencyStatusDidChangeNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(applyTheme), name: name, object: nil)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // The end of the black rectangle, as the user experiences it.
        Log.ui.note("launch: first frame at \(AppDelegate.sinceLaunch())")

        // Not in viewDidLoad. Presenting anything from there fails silently -- the view isn't in a
        // window yet, so there is nothing to present *from* -- and the symptom is simply that the
        // alert never appears.
        AppStatus.shared.windowDidAppear()
        updateTitle()

        // Settings First: the boot waits for these to close. In one window, the active one.
        if AppDelegate.bootHeldForSettings, Self.active === self {
            openSettings(nil)
        }
    }

    func makeFrame(keyboardDelta: CGFloat, _ fn: String = #function, _ ln: Int = #line) -> CGRect {
        // Whichever reaches higher: the keyboard, or the home indicator's strip when there is no
        // keyboard over it. A keyboard that is up already covers that strip, so the two don't add.
        let bottom = max(keyboardDelta, view.safeAreaInsets.bottom)

        // Inset for the rails whenever the bar is rails, even while they're hidden, so the terminal
        // doesn't reflow each time the keyboard comes and goes.
        let side = padding + (wantsRails ? KeyBar.railWidth : 0)

        let insets = terminalInsets
        return CGRect(
            x: insets.left + side,
            y: insets.top + padding,
            width: view.frame.width - insets.left - insets.right - (side * 2),
            height: view.frame.height - insets.top - bottom - (padding * 2))
    }

    /// The safe area, except that in a window it also starts below the window
    /// controls in its top corner, so that no text is under them.
    ///
    /// Below rather than beside, which would push every line in by the width of
    /// the controls when they only take up the first.
    private var terminalInsets: UIEdgeInsets {
        guard #available(iOS 26.0, *) else { return view.safeAreaInsets }
        return view.edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
    }

    /// Watches the keyboard, and the accessory bar that stands in for it when a
    /// hardware keyboard is attached.
    ///
    /// Every notification that carries the keyboard's frame, not just show and
    /// hide, because the bar can change size while it stays up. With a hardware
    /// keyboard on iPad, the bar's frame is first reported at zero height and
    /// only then at its real size, and both are only ever announced as
    /// `keyboardDidChangeFrame`: no will-show, and no will-change before them.
    /// A terminal sized at show time is left with its last rows behind it.
    func setupKeyboardMonitor() {
        for name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardFrameChanged), name: name, object: nil)
        }
    }

    @objc private func keyboardFrameChanged(_ notification: NSNotification) {
        guard
            let keyboardValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue
        else { return }

        keyboardScreenFrame = keyboardValue.cgRectValue
        updateKeyboardDelta()
    }

    /// Sizes the terminal to stop above the keyboard, or above the key bar if
    /// that reaches higher.
    ///
    /// The bar is asked where it is, rather than trusted to be inside what the
    /// keyboard reports. When it's put back after a hardware keyboard had it
    /// hidden, iOS announces the keyboard at zero height and then nothing more,
    /// though the bar is up along the bottom of the screen.
    func updateKeyboardDelta() {
        guard let screen = view.window?.screen else { return }

        // Mid-turn, the keyboard's frame is stale; see `expectKeyboardWhileTurning`.
        guard turningTo == nil else { return }

        // Only what's docked: the keyboard along the bottom of the screen, and the bar along it,
        // along the bottom of a window that doesn't fill the screen, where iPadOS puts it with a
        // hardware keyboard, or riding a docked keyboard. A floating keyboard, iPad's small one, is
        // reported where it floats, over the middle of the terminal, which then stopped short above
        // it; floating, it covers the terminal rather than pushing it up.
        let bottom = screen.bounds.maxY
        let windowBottom = view.window.map {
            $0.convert($0.bounds, to: screen.coordinateSpace).maxY
        }
        let keyboard = keyboardScreenFrame
        let keyboardDocked = keyboard.height > 0 && keyboard.maxY >= bottom - 1
        let bar = keyBar?.screenFrame.flatMap { bar in
            bar.maxY >= bottom - 1 || windowBottom.map { abs(bar.maxY - $0) <= 1 } == true
                || (keyboardDocked && abs(bar.maxY - keyboard.minY) <= 1)
                ? bar : nil
        }

        // How much of the view each covers, measured from its top edge down, rather than its
        // height: a bar that floats clear of the bottom of the screen covers the gap beneath it
        // too. One that is going away covers none.
        let covering = [keyboardDocked ? keyboard : nil, bar].compactMap { $0 }
        func covered(by frame: CGRect) -> CGFloat {
            let overlap = view.bounds.intersection(
                view.convert(frame, from: screen.coordinateSpace))
            return overlap.isEmpty ? 0 : view.bounds.maxY - overlap.minY
        }
        keyboardDelta = covering.map(covered(by:)).max() ?? 0

        // As rails, the zero-height bar marks the keyboard's top edge, or the screen's bottom with
        // a hardware keyboard, and is on screen only while the terminal has focus. The keyboard's
        // reported frame can't be trusted here: with no accessory height, it has been reported as a
        // sliver a few points high. The rails hide as soon as the terminal loses focus.
        railsBottom = nil
        if keyBar?.usesRails == true {
            let top = keyBar?.screenFrame.map {
                min(max(view.convert($0, from: screen.coordinateSpace).minY, 0), view.bounds.maxY)
            }
            if let top, terminal.isFirstResponder {
                railsBottom = top
                keyboardDelta = view.bounds.maxY - top
                keyboardBesideRails = keyboardDelta
            } else {
                keyboardDelta = 0
            }
        } else if terminal.isFirstResponder, keyboardDelta > 0 {
            keyboardUnderStrip = keyboardDelta
        }

        layoutTerminal()
    }

    /// The size being turned to, during a turn between strip and rails.
    private var turningTo: CGSize?

    /// The height the keyboard last covered with rails and with the strip, used
    /// as estimates during a turn, before the keyboard reports.
    private var keyboardBesideRails: CGFloat?
    private var keyboardUnderStrip: CGFloat?

    /// Whether the key bar should be rails: on a phone in landscape, where
    /// height is scarcest.
    private func wantsRails(at size: CGSize) -> Bool {
        traitCollection.userInterfaceIdiom == .phone && size.width > size.height
    }

    private var wantsRails: Bool { wantsRails(at: view.bounds.size) }

    /// The height the keyboard is expected to cover in a view this tall, until
    /// it reports. A hardware keyboard covers only the strip, and with rails,
    /// nothing.
    private func expectedKeyboard(rails: Bool, height: CGFloat) -> CGFloat {
        let hardware = GCKeyboard.coalesced != nil
        if rails {
            return keyboardBesideRails ?? (hardware ? 0 : height * 0.41)
        }
        return keyboardUnderStrip
            ?? (hardware ? KeyBar.height + view.safeAreaInsets.bottom : height * 0.41)
    }

    /// Flows the key bar between strip and rails during the turn, rather than
    /// after it.
    override func viewWillTransition(
        to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)

        // Only turns between strip and rails; other size changes, such as an iPad's, are untouched.
        let toRails = wantsRails(at: size)
        guard toRails != wantsRails else { return }

        turningTo = size
        if let keyBar, toRails != keyBar.usesRails {
            if toRails {
                keyBar.turnIntoRails(
                    height: size.height - expectedKeyboard(rails: true, height: size.height))
            } else {
                keyBar.beginReturningToStrip()
            }
        }

        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self, let keyBar, !toRails, keyBar.usesRails else { return }
            let keyboard = expectedKeyboard(rails: false, height: size.height)
            keyBar.flowIntoStrip(barTop: size.height - keyboard, width: size.width)
        }) { [weak self] _ in
            guard let self else { return }
            turningTo = nil
            keyBar?.usesRails = wantsRails
            updateKeyboardDelta()
        }
    }

    /// Sizes the terminal on every layout pass, which rotation and every other
    /// change of size go through, so nothing else needs to.
    override func viewWillLayoutSubviews() {
        if turningTo != nil {
            expectKeyboardWhileTurning()
        } else {
            keyBar?.usesRails = wantsRails
        }

        layoutTerminal()
    }

    /// Estimates where the keyboard will be after the turn, for layout during
    /// it, as the keyboard reports its frame only afterwards.
    private func expectKeyboardWhileTurning() {
        let height = view.bounds.height
        let rails = keyBar?.usesRails == true && wantsRails
        let covered = terminal.isFirstResponder ? expectedKeyboard(rails: rails, height: height) : 0

        keyboardDelta = covered
        railsBottom =
            rails && terminal.isFirstResponder && keyBar?.window != nil ? height - covered : nil
    }

    /// Lays out the terminal around the keyboard and rails, and the rails, if
    /// shown, either side of it.
    private func layoutTerminal() {
        // While the switcher is open, the terminal frame stays as it was. The switcher takes the
        // keyboard, so the terminal would otherwise grow into the space the keyboard leaves, then
        // shrink again when the switcher closes and the keyboard returns: two resizes for nothing.
        // A new view size, from the device turning, still resizes it, for the keyboard it will have
        // once the switcher closes, so the switcher's cards take the new shape.
        if switcher == nil {
            ttyWindow.terminalFrame = makeFrame(keyboardDelta: keyboardDelta)
        } else if view.bounds.size != sizeUnderSwitcher {
            sizeUnderSwitcher = view.bounds.size
            let keyboard =
                keyboardBeforeSwitcher
                ? expectedKeyboard(rails: wantsRails, height: view.bounds.height) : 0
            ttyWindow.terminalFrame = makeFrame(keyboardDelta: keyboard)
        }
        layoutFindBar()
        scheduleFloatingSwitcherUpdate()

        // Set on every layout, as autoresizing left it at its portrait size, and a rail outside it
        // can't be touched. The switcher's view is set to fill the view on every layout too.
        keyBar?.rails.frame = view.bounds
        switcher?.view.frame = view.bounds

        let insets = view.safeAreaInsets
        keyBar?.placeRails(
            in: railsBottom.map { bottom in
                CGRect(
                    x: insets.left, y: insets.top,
                    width: view.bounds.width - insets.left - insets.right,
                    height: max(0, bottom - insets.top))
            })
    }
}

// MARK: - Keyboard

extension ViewController {

    /// ⌘, from the app menu; see `AppDelegate.buildMenu(with:)`. Reached
    /// through the responder chain from the terminal, which holds focus.
    ///
    /// Does nothing while something is already up over the terminal: the
    /// settings sheet itself, or an alert that wants answering first.
    @objc func openSettings(_ sender: Any?) {
        guard presentedViewController == nil else { return }
        SettingsViewController.present(from: self)
    }

    /// View > Show Key Bar With Hardware Keyboard, from the menu bar; the same
    /// setting as Settings > Keyboard has, the other way up.
    @objc func toggleKeyBarWithHardwareKeyboard(_ sender: Any?) {
        AppSetting.hideKeyBarWithHardwareKeyboard.set(
            !AppSetting.hideKeyBarWithHardwareKeyboard.bool)
    }

    /// View > Customize Toolbar…, from the menu bar: straight to the key bar's
    /// pinned keys in Settings.
    @objc func customizeKeyBar(_ sender: Any?) {
        guard presentedViewController == nil else { return }
        SettingsViewController.present(from: self, showing: .pinnedKeys)
    }

    /// Ticks the menu bar's settings that are on, names the commands that say
    /// what they'll do to the selected TTY, or to Linux, and lists the TTYs
    /// that ⌘1 to ⌘9 show.
    override func validate(_ command: UICommand) {
        super.validate(command)

        let tty = ttyWindow.selected
        switch command.action {
        case #selector(toggleKeyBarWithHardwareKeyboard(_:)):
            command.state = AppSetting.hideKeyBarWithHardwareKeyboard.bool ? .off : .on
        case #selector(togglePinned(_:)):
            command.title = tty.isPinned ? "Unpin Terminal" : "Pin Terminal"
        case #selector(toggleMuted(_:)):
            command.title = tty.isMuted ? "Unmute Terminal" : "Mute Terminal"
        // Move Terminal to lists the other windows by name.
        case #selector(moveTTYToWindow(_:)):
            let target = otherWindow(command.propertyList as? Int)
            command.title = target?.title ?? command.title
            command.attributes = target != nil ? [] : .hidden
        // Each TTY that ⌘1 to ⌘8 shows is listed by name, and those past the last are hidden. ⌘9,
        // for the last, is listed only once there are nine or more: before then, the last TTY is
        // already listed with its own number. A hidden shortcut still works.
        case #selector(jumpToTTY(_:)):
            let number = command.propertyList as? Int ?? 0
            let target = jumpTarget(number)
            let listed = number < 9 || ttyWindow.stepOrder.count >= 9
            command.title = target?.name ?? command.title
            command.attributes = target != nil && listed ? [] : .hidden
        // A system TTY in this window's step order is listed with ⌘1 to ⌘9 instead.
        case #selector(showKernelLog(_:)):
            command.attributes = listsSystemTTY(.kernelLog) ? [] : .hidden
        case #selector(showVMManagement(_:)):
            command.attributes = listsSystemTTY(.vmManagement) ? [] : .hidden
        case #selector(switchBackend(_:)):
            command.title = Backend.current == .native ? "Switch to TCTI…" : "Switch to JIT…"
        case #selector(setExecutionMode(_:)):
            let mode = command.propertyList as? String
            command.state = mode == ExecutionMode.setting.rawValue ? .on : .off
        case #selector(setVcpus(_:)):
            command.state = command.propertyList as? Int == Vcpus.foreground ? .on : .off
        case #selector(toggleKeepScreenAwake(_:)):
            command.state = AppSetting.keepScreenAwake.bool ? .on : .off
        case #selector(setDarkTheme(_:)):
            let id = command.propertyList as? String
            command.state = id == TerminalThemes.selected(for: .dark).id ? .on : .off
        case #selector(setLightTheme(_:)):
            let id = command.propertyList as? String
            command.state = id == TerminalThemes.selected(for: .light).id ? .on : .off
        default:
            break
        }
    }

    /// On iPhone, which has no menu bar, the shortcuts that the menu bar holds
    /// on iPad; see `MenuBar`. Not on iPad, where the menu bar's commands
    /// already answer these keys and a second set would only compete with them,
    /// except for the alternates that a menu item can't show.
    override var keyCommands: [UIKeyCommand]? {
        let commands =
            traitCollection.userInterfaceIdiom == .phone
            ? MenuBar.phoneKeyCommands : MenuBar.alternateKeyCommands
        return (super.keyCommands ?? []) + commands
    }
}

// MARK: - TTYs

extension ViewController {

    /// Wires up both switcher buttons, the key bar's and the floating one, and
    /// puts each newly selected TTY's terminal on screen.
    fileprivate func setUpTTYs() {
        for button in [keyBar?.switcher, floatingSwitcher.button].compactMap({ $0 }) {
            button.open = { [weak self] in self?.openSwitcher() }
            button.step = { [weak self] offset in self?.step(by: offset) }
            button.ttyMenu = { [weak self] interaction in
                guard let self, switcher == nil, presentedViewController == nil else { return nil }
                return ttyMenu.menu(for: ttyWindow.selected, in: interaction)
            }
            button.add = { [weak self] in self?.stepToNew() }
            button.pull = { [weak self] offset in
                guard let self else { return .none }
                if ttyWindow.neighbor(by: offset) != nil {
                    return .step
                }
                guard offset > 0 else { return .none }
                return TTYs.shared.canAdd ? .add : .full
            }
            button.atLimit = { [weak self] in self?.explainTTYLimit() }
            button.ttyWindow = ttyWindow
        }

        floatingSwitcher.alpha = 0
        floatingSwitcher.isHidden = true
        view.addSubview(floatingSwitcher)

        followButton.alpha = 0
        followButton.isHidden = true
        followButton.onTap = { [weak self] in self?.terminal.follow() }
        view.addSubview(followButton)

        observers.append(
            NotificationCenter.default.addObserver(
                forName: TctiTermView.followingDidChange, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, note.object as? TctiTermView === terminal else { return }
                updateFollowButton()
            })

        observers.append(
            NotificationCenter.default.addObserver(
                forName: TTYs.selectionDidChange, object: ttyWindow, queue: .main
            ) { [weak self] note in
                guard let self else { return }
                showSelected(replacing: note.userInfo?[TTYs.previousKey] as? TTY)
                updateFollowButton()
                updateSerialSize()
                updateTitle()
            })

        // A window's title names its TTYs.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: TTYs.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.updateTitle()
            })

        NotificationCenter.default.addObserver(
            self, selector: #selector(couldNotEndPrograms), name: TTYs.couldNotEndPrograms,
            object: nil)

        observers.append(
            NotificationCenter.default.addObserver(
                forName: TTYs.windowDidClose, object: ttyWindow, queue: .main
            ) { [weak self] _ in
                self?.windowDidClose()
            })

        // A TTY dragged from another window's switcher onto the terminal moves here.
        view.addInteraction(UIDropInteraction(delegate: self))
    }

    /// Names the window, in App Exposé and the window list, for its selected
    /// TTY, and how many others it has.
    func updateTitle() {
        view.window?.windowScene?.title = ttyWindow.title
    }

    /// Detaches the key bar and Find from the terminal that was on screen when
    /// the window closed. If that TTY moved to another window, that window
    /// attaches its key bar as it shows it.
    private func windowDidClose() {
        windowClosed = true
        closeFindBar(refocus: false)
        if let keyBar, terminal.inputAccessoryView === keyBar {
            terminal.inputAccessoryView = nil
        }
        keyBar?.terminal = nil
    }

    private static let serialSizeStatusKey = "serial-size"

    /// The serial port has no way to be told the terminal's size, so the first
    /// time something is typed into Kernel Log in each launch, say how to set
    /// it by hand, for the size the terminal has. Kept, and kept up to date,
    /// until it is swiped away, but shown only in the window where Kernel Log
    /// is selected.
    private func explainSerialSize() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: Self.serialSizeDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.updateSerialSize()
            })

        // Set up only by the first window to get here: Kernel Log has one terminal, shared by every
        // window.
        guard let view = Self.kernelLog?.view, view.onTyping == nil, !Self.serialSizeShown else {
            return
        }
        view.onTyping = { [weak view] in
            view?.onTyping = nil
            Self.serialSizeShown = true
            NotificationCenter.default.post(name: Self.serialSizeDidChange, object: nil)
        }
        ChardevTransport.kernelLog.onResize = { _, _ in
            guard Self.serialSizeShown else { return }
            NotificationCenter.default.post(name: Self.serialSizeDidChange, object: nil)
        }
    }

    private static var kernelLog: TTY? {
        TTYs.shared.system.first { $0.kind == .kernelLog }
    }

    /// Shows the pill if it's up and Kernel Log is selected here, and takes it
    /// away otherwise.
    private func updateSerialSize() {
        guard Self.serialSizeShown, ttyWindow.selected.kind == .kernelLog,
            let t = Self.kernelLog?.view?.getTerminal()
        else {
            status?.dismiss(key: Self.serialSizeStatusKey)
            return
        }
        status?.present(
            .init(
                key: Self.serialSizeStatusKey,
                message: "Size ttyS0 by hand: stty rows \(t.rows) cols \(t.cols)",
                state: .symbol("ruler"),
                duration: nil,
                animated: false,
                onSwipeAway: {
                    Self.serialSizeShown = false
                    NotificationCenter.default.post(name: Self.serialSizeDidChange, object: nil)
                }))
    }

    /// Puts the selected TTY's terminal on screen in place of `previous`'s, and
    /// moves the key bar and the keyboard to it.
    private func showSelected(replacing previous: TTY?) {
        // Typing in the find bar counts as typing in the terminal it searches: either way, the
        // incoming terminal takes the keyboard.
        let typing = previous?.view?.isFirstResponder == true || findBar?.isTyping == true
        closeFindBar(refocus: false)

        let incoming = terminal
        let outgoing = previous?.view
        guard incoming !== outgoing else { return }

        let sliding = incoming.superview === view

        // Set by bounds and center rather than frame: the incoming terminal may still carry the
        // translation of an earlier slide, and setting the frame of a transformed view would fold
        // the translation in.
        let frame = ttyWindow.terminalFrame
        incoming.bounds.size = frame.size
        incoming.center = CGPoint(x: frame.midX, y: frame.midY)
        if let outgoing, outgoing.superview === view {
            view.insertSubview(incoming, aboveSubview: outgoing)
        } else {
            view.insertSubview(incoming, at: 0)
        }

        // Point the key bar at the incoming terminal before it takes the keyboard, because the
        // terminal's input accessory view is read as it becomes first responder.
        keyBar?.terminal = incoming
        if typing {
            _ = incoming.becomeFirstResponder()
        }

        guard let outgoing else { return }
        outgoing.inputAccessoryView = nil

        // After a step, the terminals slide across as pages do, the next coming in from the right.
        // Otherwise, or with Reduce Motion on, the outgoing terminal is swapped out at once.
        guard let direction = slideDirection, !UIAccessibility.isReduceMotionEnabled else {
            incoming.transform = .identity
            outgoing.removeFromSuperview()
            outgoing.transform = .identity
            slidePages.values.forEach { $0.removeFromSuperview() }
            slidePages.removeAll()
            slideBackdrop?.removeFromSuperview()
            slideBackdrop = nil
            return
        }
        let distance = (view.bounds.width + Self.slideGap) * CGFloat(direction)
        let incomingPage = slidePage(for: incoming)
        let outgoingPage = slidePage(for: outgoing)
        if !sliding {
            incoming.transform = CGAffineTransform(translationX: distance, y: 0)
            incomingPage.transform = incoming.transform
        }

        slidesUnderway += 1
        slidOut.append(outgoing)
        UIView.animate(
            withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            incoming.transform = .identity
            incomingPage.transform = .identity
            outgoing.transform = CGAffineTransform(translationX: -distance, y: 0)
            outgoingPage.transform = outgoing.transform
        } completion: { [weak self] _ in
            guard let self else { return }
            slidesUnderway -= 1
            guard slidesUnderway == 0 else { return }

            // Remove the slid-out terminals only once every slide has finished: a later slide may
            // be moving one of them out again, or back in, in which case it is now the selected
            // terminal and stays. One that moved to another window meanwhile is that window's now.
            for outgoing in slidOut where outgoing !== terminal {
                if outgoing.superview === view {
                    outgoing.removeFromSuperview()
                }
                outgoing.transform = .identity
            }
            slidOut.removeAll()
            slidePages.values.forEach { $0.removeFromSuperview() }
            slidePages.removeAll()
            slideBackdrop?.removeFromSuperview()
            slideBackdrop = nil
        }
    }

    /// The width of the black gap between terminals as they slide.
    private static let slideGap: CGFloat = 8

    /// Returns the page that `terminal` slides on, making it if needed. The
    /// page is the size of the screen, filled with the terminal's background
    /// color and rounded at the screen's corners, so each sliding terminal
    /// looks like the whole screen as seen at rest. Also makes the black
    /// backdrop that the pages slide over, if there isn't one yet.
    private func slidePage(for terminal: TctiTermView) -> UIView {
        if slideBackdrop == nil {
            let backdrop = UIView(frame: view.bounds)
            backdrop.backgroundColor = .black
            backdrop.isUserInteractionEnabled = false
            view.insertSubview(backdrop, at: 0)
            slideBackdrop = backdrop
        }
        if let page = slidePages[ObjectIdentifier(terminal)] {
            return page
        }

        let page = UIView()
        page.bounds = view.bounds
        page.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        page.backgroundColor = terminal.nativeBackgroundColor
        page.layer.cornerRadius = Self.displayCornerRadius(of: view.window?.screen)
        page.layer.cornerCurve = .continuous
        page.isUserInteractionEnabled = false
        view.insertSubview(page, belowSubview: terminal)
        slidePages[ObjectIdentifier(terminal)] = page
        return page
    }

    /// The corner radius of `screen`, read from UIKit's private
    /// `_displayCornerRadius`, or 0 (square corners) when that isn't available.
    private static func displayCornerRadius(of screen: UIScreen?) -> CGFloat {
        let key = "_displayCornerRadius"
        guard let screen, screen.responds(to: NSSelectorFromString(key)) else { return 0 }
        return screen.value(forKey: key) as? CGFloat ?? 0
    }

    // MARK: Stepping

    /// Steps to the next or previous TTY in the step order, for a pull on the
    /// switcher button or a key command, then shows the step pill. At either
    /// end of the order, only the pill shows.
    func step(by offset: Int) {
        if let next = ttyWindow.neighbor(by: offset) {
            slide(offset > 0 ? 1 : -1) { TTYs.shared.select(next) }
            UISelectionFeedbackGenerator().selectionChanged()
        }
        showStepPill()
    }

    /// Adds a TTY after the last and steps to it, for a pull on the switcher
    /// button past the last TTY.
    private func stepToNew() {
        guard let tty = TTYs.shared.add(to: ttyWindow) else { return }
        slide(1) { TTYs.shared.select(tty) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showStepPill()
    }

    /// Runs `select`, which changes the selection, with the terminals sliding
    /// in `direction`: +1 or -1.
    private func slide(_ direction: Int, _ select: () -> Void) {
        slideDirection = direction
        defer { slideDirection = nil }
        select()
    }

    /// Briefly shows the selected TTY's name and its position in the step
    /// order, such as "hvc3 · 4/7", next to the switcher button.
    private func showStepPill() {
        let order = ttyWindow.stepOrder
        let selected = ttyWindow.selected

        // A system TTY outside the step order has no position in it, so only its name shows.
        let pill = stepPill ?? makeStepPill()
        if let index = order.firstIndex(where: { $0 === selected }) {
            pill.text = "\(selected.name) · \(index + 1)/\(order.count)"
        } else {
            pill.text = selected.name
        }
        UIAccessibility.post(notification: .announcement, argument: pill.text)

        // Place the pill above whichever switcher button is showing, right-aligned with it and
        // inside the safe area. Where there's no room above, as at the top of a rail, place it to
        // the button's left instead.
        let size = pill.intrinsicContentSize
        let width = size.width + 24
        let height: CGFloat = 30
        let button = switcherButtonFrame()
        if button.minY - height - 8 >= view.safeAreaInsets.top {
            pill.frame = CGRect(
                x: min(
                    button.maxX - width, view.bounds.maxX - view.safeAreaInsets.right - 8 - width),
                y: button.minY - height - 8, width: width, height: height)
        } else {
            pill.frame = CGRect(
                x: button.minX - width - 8, y: button.midY - height / 2, width: width,
                height: height)
        }
        pill.layer.cornerRadius = height / 2

        UIView.animate(withDuration: 0.15) { pill.alpha = 1 }

        stepPillExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak pill] in
            UIView.animate(withDuration: 0.3) { pill?.alpha = 0 }
        }
        stepPillExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: expiry)
    }

    private func makeStepPill() -> UILabel {
        let pill = UILabel()
        pill.font = .preferredFont(forTextStyle: .footnote)
        pill.textColor = .white
        pill.textAlignment = .center
        pill.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true
        pill.alpha = 0
        pill.isUserInteractionEnabled = false
        view.addSubview(pill)
        stepPill = pill
        return pill
    }

    /// The frame of the switcher button on screen, in this view's coordinates,
    /// or where the floating button goes if neither button is on screen.
    private func switcherButtonFrame() -> CGRect {
        var button: UIView?
        if floatingSwitcherShown {
            button = floatingSwitcher
        } else if let bar = keyBar?.switcher, bar.window != nil {
            button = bar
        }
        guard let button, let screen = view.window?.screen else {
            return floatingSwitcherFrame()
        }
        let onScreen = button.convert(button.bounds, to: screen.coordinateSpace)
        return view.convert(onScreen, from: screen.coordinateSpace)
    }

    // MARK: The floating switcher button

    /// The floating button's frame: at the bottom right of the safe area, near
    /// where the trailing capsule or the right rail would be.
    private func floatingSwitcherFrame() -> CGRect {
        let size = FloatingSwitcher.size
        let insets = view.safeAreaInsets
        return CGRect(
            x: view.bounds.maxX - insets.right - 8 - size,
            y: view.bounds.maxY - max(insets.bottom, 8) - size, width: size, height: size)
    }

    /// Positions the floating button now, and decides whether to show it on the
    /// next turn of the run loop rather than at once: moving the keyboard from
    /// one terminal to another takes the key bar off screen and puts it back
    /// within one turn, which would otherwise flash the floating button.
    private func scheduleFloatingSwitcherUpdate() {
        // Set by bounds and center rather than frame: while hidden it keeps a 0.6 scale transform,
        // and setting a frame on a transformed view resizes it to compensate.
        let frame = floatingSwitcherFrame()
        floatingSwitcher.bounds.size = frame.size
        floatingSwitcher.center = CGPoint(x: frame.midX, y: frame.midY)

        let follow = followButtonFrame()
        followButton.bounds.size = follow.size
        followButton.center = CGPoint(x: follow.midX, y: follow.midY)

        guard !floatingSwitcherPending else { return }
        floatingSwitcherPending = true
        DispatchQueue.main.async { [weak self] in
            self?.floatingSwitcherPending = false
            self?.updateFloatingSwitcher()
        }
    }

    /// Shows the floating button while the key bar is off screen and neither
    /// the switcher nor the find bar is open, and hides it otherwise.
    private func updateFloatingSwitcher() {
        updateFollowButton()

        let show = switcher == nil && findBar == nil && keyBar?.window == nil
        guard show != floatingSwitcherShown else { return }
        floatingSwitcherShown = show

        view.bringSubviewToFront(floatingSwitcher)
        if show {
            floatingSwitcher.isHidden = false
            floatingSwitcher.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }
        UIView.animate(
            withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.floatingSwitcher.alpha = show ? 1 : 0
            self.floatingSwitcher.transform =
                show ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        } completion: { _ in
            if !self.floatingSwitcherShown {
                self.floatingSwitcher.isHidden = true
            }
        }
    }

    // MARK: The follow button

    /// The follow button's frame: at the top left of the terminal, or under the
    /// find bar while that is open.
    private func followButtonFrame() -> CGRect {
        let terminal = ttyWindow.terminalFrame
        let size = FollowButton.size
        let top = terminal.minY + (findBar == nil ? 0 : FindBar.height) + 8
        return CGRect(x: terminal.minX + 8, y: top, width: size, height: size)
    }

    /// Shows the follow button while the selected terminal has been scrolled up
    /// from its newest output and the switcher is closed, and hides it
    /// otherwise.
    private func updateFollowButton() {
        let show = switcher == nil && !terminal.isFollowing
        guard show != followButtonShown else { return }
        followButtonShown = show

        // Brought forward only to show it: on the way out, it fades under the switcher.
        if show {
            view.bringSubviewToFront(followButton)
            followButton.isHidden = false
            followButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }
        UIView.animate(
            withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.followButton.alpha = show ? 1 : 0
            self.followButton.transform = show ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        } completion: { _ in
            if !self.followButtonShown {
                self.followButton.isHidden = true
            }
        }
    }

    // MARK: The switcher

    @objc func toggleSwitcher(_ sender: Any?) {
        if let switcher {
            switcher.finish(nil)
        } else {
            openSwitcher()
        }
    }

    func openSwitcher() {
        guard switcher == nil, presentedViewController == nil else { return }
        keyboardBeforeSwitcher = terminal.isFirstResponder || findBar?.isTyping == true
        closeFindBar(refocus: false)

        sizeUnderSwitcher = view.bounds.size

        let controller = TTYSwitcherViewController(window: ttyWindow)
        controller.finish = { [weak self] find in self?.closeSwitcher(find: find) }
        switcher = controller

        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)

        // As first responder, the switcher takes focus from the terminal, so the software keyboard
        // goes down, and it receives the key commands.
        _ = controller.becomeFirstResponder()
        scheduleFloatingSwitcherUpdate()

        controller.animateIn(from: terminal)
    }

    /// Closes the switcher onto the selected TTY, and opens the find bar on it
    /// if `find` is given, searching for `find` unless it is empty.
    private func closeSwitcher(find: String?) {
        guard let controller = switcher, controller.parent === self else { return }

        // Ignore further requests to finish, from a second tap or a key command, while the switcher
        // animates out.
        controller.finish = { _ in }
        controller.view.isUserInteractionEnabled = false
        switcherClosing = true

        controller.animateOut(to: terminal) { [weak self] in
            guard let self else { return }

            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()

            // Give the keyboard back before clearing `switcher`, while the terminal frame is still
            // held, so that the terminal is laid out once, around the keyboard, rather than first
            // without it.
            if let find {
                openFindBar(term: find.isEmpty ? nil : find)
            } else if keyboardBeforeSwitcher {
                _ = terminal.becomeFirstResponder()
            }

            switcher = nil
            switcherClosing = false
            view.setNeedsLayout()
            scheduleFloatingSwitcherUpdate()
        }
    }

    // MARK: Closing

    /// Asks before closing the selected TTY, as the switcher's X does.
    private func confirmClosingSelected() {
        let tty = ttyWindow.selected
        guard !tty.isSystem, presentedViewController == nil else { return }
        ttyMenu.confirmClose(tty)
    }

    // MARK: Finding

    /// Edit > Find > Find…, or ⌘F: opens the find bar, or focuses its field if
    /// it's already open.
    @objc override func find(_ sender: Any?) {
        guard switcher == nil, presentedViewController == nil else { return }
        if let findBar {
            findBar.focus()
        } else {
            openFindBar()
        }
    }

    /// Edit > Find > Find Next, or ⌘G, while the find bar is open.
    @objc override func findNext(_ sender: Any?) {
        findBar?.step(back: false)
    }

    /// Edit > Find > Find Previous, or ⌘⇧G, while the find bar is open.
    @objc override func findPrevious(_ sender: Any?) {
        findBar?.step(back: true)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // A closed window's scene can linger a moment, and its TTYs are now another window's.
        guard !windowClosed else { return false }
        let tty = ttyWindow.selected
        let free = presentedViewController == nil

        switch action {
        case #selector(find(_:)):
            return switcher == nil && free
        case #selector(useSelectionForFind(_:)):
            return switcher == nil && free && terminal.hasActiveSelection
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return findBar != nil
        // Off while this is the only window.
        case #selector(closeWindow(_:)), #selector(closeWindowOtherwise(_:)),
            #selector(moveTTYToWindow(_:)), #selector(mergeAllWindows(_:)):
            return free && TTYs.shared.windows.count > 1
        case #selector(openNewWindow(_:)):
            return free && WindowScenes.areAvailable
        // A window's only TTY would leave behind a window with none.
        case #selector(moveTTYToNewWindow(_:)):
            return free && WindowScenes.areAvailable && ttyWindow.ordered.count > 1
                && TTYs.shared.canMove(tty)
        // Close TTY and Close Other TTYs stay on, and do nothing while an alert or a sheet is up.
        // Turned off, they would let ⌘W and ⌥⌘W through to whatever the system has for them.
        case #selector(closeTTY(_:)), #selector(closeOtherTTYs(_:)):
            return true
        // The other commands are off while an alert or a sheet is up, such as one from the
        // switcher.
        case #selector(newTTY(_:)), #selector(toggleSwitcher(_:)),
            #selector(previousTTY(_:)), #selector(nextTTY(_:)), #selector(jumpToTTY(_:)),
            #selector(toggleMuted(_:)), #selector(exportText(_:)), #selector(clearScrollback(_:)):
            return free
        case #selector(renameTTY(_:)), #selector(togglePinned(_:)):
            return free && !tty.isSystem
        case #selector(makeTextBigger(_:)):
            return free && TTYMenu.fontSizes.contains(fontSize(of: tty) + 1)
        case #selector(makeTextSmaller(_:)):
            return free && TTYMenu.fontSizes.contains(fontSize(of: tty) - 1)
        case #selector(useDefaultFontSize(_:)):
            return free && tty.fontSize != nil
        case #selector(scrollToTop(_:)), #selector(scrollToBottom(_:)):
            return free && switcher == nil && !terminal.getTerminal().isCurrentBufferAlternate
        case #selector(showKernelLog(_:)):
            return free && TTYs.isShown(.kernelLog)
        case #selector(showVMManagement(_:)):
            return free && TTYs.isShown(.vmManagement)
        case #selector(switchBackend(_:)):
            return free && Backend.current != nil && !Backend.isBusy
        case #selector(setExecutionMode(_:)), #selector(setVcpus(_:)),
            #selector(toggleKeepScreenAwake(_:)), #selector(confirmRecoveryBoot(_:)),
            #selector(compactDisk(_:)):
            return free
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    /// Opens the find bar over the selected TTY's terminal.
    func openFindBar(term: String? = nil) {
        closeFindBar(refocus: false)

        let bar = FindBar()
        bar.overrideUserInterfaceStyle = overlayStyle
        bar.glassTint = glassTint
        bar.terminal = terminal
        bar.close = { [weak self] in self?.closeFindBar(refocus: true) }
        findBar = bar
        view.addSubview(bar)
        layoutFindBar()

        bar.begin(with: term)
        scheduleFloatingSwitcherUpdate()
    }

    private func closeFindBar(refocus: Bool) {
        guard let bar = findBar else { return }
        findBar = nil
        bar.end()
        bar.removeFromSuperview()

        if refocus {
            _ = terminal.becomeFirstResponder()
        }
        scheduleFloatingSwitcherUpdate()
    }

    /// Places the find bar along the top of the terminal, centered, and at most
    /// 520 points wide.
    private func layoutFindBar() {
        guard let findBar else { return }
        let frame = ttyWindow.terminalFrame
        let width = min(frame.width, 520)
        findBar.frame = CGRect(
            x: frame.midX - width / 2, y: frame.minY, width: width, height: FindBar.height)
    }

    // MARK: Menu bar commands

    // The menu bar's commands, which `MenuBar` lists with their shortcuts.

    /// Edit > Find > Use Selection for Find, or ⌘E: opens the find bar on the
    /// selected text.
    @objc override func useSelectionForFind(_ sender: Any?) {
        let text = terminal.selection.getSelectedText()
        guard switcher == nil, presentedViewController == nil, !text.isEmpty else { return }
        openFindBar(term: text)
    }

    @objc func newTTY(_ sender: Any?) {
        // With the switcher open, it adds the TTY and closes onto it.
        if let switcher {
            switcher.add()
            return
        }
        guard let tty = TTYs.shared.add(to: ttyWindow) else {
            explainTTYLimit()
            return
        }
        TTYs.shared.select(tty)
    }

    /// Says, in a pill, that no more TTYs can be opened.
    private func explainTTYLimit() {
        presentOverSwitcher(TTYs.limitPill)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Shows a pill over the switcher while it's open, and over the terminal
    /// otherwise, as when the switcher is on its way out.
    private func presentOverSwitcher(_ item: StatusPresenter.Item) {
        if let switcher, !switcherClosing {
            switcher.present(item)
        } else {
            status?.present(item)
        }
    }

    /// Says that the programs on closed TTYs' consoles couldn't be ended.
    @objc private func couldNotEndPrograms(_ notification: Notification) {
        guard Self.active === self, let message = notification.object as? String else { return }
        presentOverSwitcher(
            .init(key: "end-programs", message: message, state: .failed, duration: 5))
    }

    /// Close Window, or ⌘⇧W: closes this window and its terminals, keeping
    /// their programs running or ending them as Settings says. Off while it's
    /// the only window.
    @objc func closeWindow(_ sender: Any?) {
        closeWindow(endingPrograms: !AppSetting.keepProgramsWhenClosingWindow.bool)
    }

    /// The item under Close Window, which does the other.
    @objc func closeWindowOtherwise(_ sender: Any?) {
        closeWindow(endingPrograms: AppSetting.keepProgramsWhenClosingWindow.bool)
    }

    private func closeWindow(endingPrograms: Bool) {
        guard presentedViewController == nil, TTYs.shared.windows.count > 1 else { return }
        TTYs.shared.closeWindow(ttyWindow, endingPrograms: endingPrograms)
    }

    /// File > New Window, or ⌘N: opens a window with a new TTY in it, or at the
    /// limit, says so.
    @objc func openNewWindow(_ sender: Any?) {
        guard presentedViewController == nil, WindowScenes.areAvailable else { return }
        WindowScenes.openNewWindow()
    }

    /// File > Move Terminal to New Window: opens a window, and moves the
    /// selected TTY to it.
    @objc func moveTTYToNewWindow(_ sender: Any?) {
        guard presentedViewController == nil, ttyWindow.ordered.count > 1 else { return }
        WindowScenes.openWindow(moving: ttyWindow.selected)
    }

    /// File > Move Terminal to, one item for each other window: moves the
    /// selected TTY there.
    @objc func moveTTYToWindow(_ sender: UICommand) {
        guard presentedViewController == nil,
            let target = otherWindow(sender.propertyList as? Int)
        else { return }
        TTYs.shared.move(ttyWindow.selected, to: target)
    }

    /// The window that Move Terminal to lists at `index`: the windows other
    /// than this one that a scene shows, in the order they were made.
    private func otherWindow(_ index: Int?) -> TTYWindow? {
        let others = TTYs.shared.windows.filter { $0 !== ttyWindow && WindowScenes.shows($0) }
        guard let index, others.indices.contains(index) else { return nil }
        return others[index]
    }

    /// Window > Merge All Windows: moves every TTY here, after this window's,
    /// and closes the other windows.
    @objc func mergeAllWindows(_ sender: Any?) {
        guard presentedViewController == nil else { return }
        TTYs.shared.merge(into: ttyWindow)
    }

    @objc func closeTTY(_ sender: Any?) {
        confirmClosingSelected()
    }

    @objc func previousTTY(_ sender: Any?) {
        step(by: -1)
    }

    @objc func nextTTY(_ sender: Any?) {
        step(by: 1)
    }

    @objc func jumpToTTY(_ sender: UIKeyCommand) {
        guard let tty = jumpTarget(sender.propertyList as? Int ?? 0) else { return }
        TTYs.shared.select(tty)
    }

    /// The TTY that ⌘`number` shows: the one at that position in the step
    /// order, or the last for ⌘9. Nil if there is none.
    private func jumpTarget(_ number: Int) -> TTY? {
        let order = ttyWindow.stepOrder
        let index = number == 9 ? order.count - 1 : number - 1
        return order.indices.contains(index) ? order[index] : nil
    }

    /// Whether the Window menu lists a system TTY on its own: while Settings
    /// shows it, and it is not in this window's step order.
    private func listsSystemTTY(_ kind: TTY.Kind) -> Bool {
        guard TTYs.isShown(kind), let tty = TTYs.shared.system.first(where: { $0.kind == kind })
        else { return false }
        return !AppSetting.stepThroughSystemTTYs.bool || !ttyWindow.contains(tty)
    }

    @objc func closeOtherTTYs(_ sender: Any?) {
        let tty = ttyWindow.selected
        guard !tty.isSystem, presentedViewController == nil else { return }
        ttyMenu.confirmCloseOthers(tty)
    }

    @objc func renameTTY(_ sender: Any?) {
        ttyMenu.rename(ttyWindow.selected)
    }

    @objc func togglePinned(_ sender: Any?) {
        let tty = ttyWindow.selected
        TTYs.shared.setPinned(tty, !tty.isPinned)
    }

    @objc func toggleMuted(_ sender: Any?) {
        let tty = ttyWindow.selected
        TTYs.shared.setMuted(tty, !tty.isMuted)
    }

    /// File > Export Text As…, or ⌘S: saves the selected TTY's text, its
    /// scrollback included, to a file of the user's choosing.
    @objc func exportText(_ sender: Any?) {
        let tty = ttyWindow.selected
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Export", isDirectory: true)
        let name = tty.name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("\(name).txt")

        // The picker copies the file, so the last one exported can go once the next is asked for.
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try tty.view.transcript.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            Log.ui.warn("export: couldn't write \(file.lastPathComponent): \(error)")
            showAlert(title: "Couldn't Export Text", message: error.localizedDescription)
            return
        }

        present(UIDocumentPickerViewController(forExporting: [file], asCopy: true), animated: true)
    }

    /// Edit > Clear Scrollback, or ⌘K: forgets the selected TTY's lines above
    /// the screen. Only tctiSH holds them, so Linux sees no change.
    @objc func clearScrollback(_ sender: Any?) {
        terminal.clearScrollback()
        terminal.follow()
    }

    /// The font size the selected TTY has: its own, or the default.
    private func fontSize(of tty: TTY) -> Int {
        tty.fontSize ?? AppSetting.fontSize.integer
    }

    /// View > Bigger, or ⌘+, as the TTY menu's font size row.
    @objc func makeTextBigger(_ sender: Any?) {
        stepFontSize(by: 1)
    }

    /// View > Smaller, or ⌘−.
    @objc func makeTextSmaller(_ sender: Any?) {
        stepFontSize(by: -1)
    }

    private func stepFontSize(by step: Int) {
        let tty = ttyWindow.selected
        let size = fontSize(of: tty) + step
        guard TTYMenu.fontSizes.contains(size) else { return }
        TTYs.shared.setFontSize(tty, size)
    }

    /// View > Default Font Size, or ⌘0: back to the size Settings gives.
    @objc func useDefaultFontSize(_ sender: Any?) {
        TTYs.shared.setFontSize(ttyWindow.selected, nil)
    }

    /// View > Scroll to Top, or ⌘Home.
    @objc func scrollToTop(_ sender: Any?) {
        terminal.scrollToTop()
    }

    /// View > Scroll to Bottom, or ⌘End: back to following new output.
    @objc func scrollToBottom(_ sender: Any?) {
        terminal.follow()
    }

    /// Window > Kernel Log, while Settings shows it.
    @objc func showKernelLog(_ sender: Any?) {
        showSystemTTY(.kernelLog)
    }

    /// Window > VM Management, while Settings shows it.
    @objc func showVMManagement(_ sender: Any?) {
        showSystemTTY(.vmManagement)
    }

    /// Selects a system TTY here, moving it from the window it's in, if any.
    private func showSystemTTY(_ kind: TTY.Kind) {
        guard let tty = TTYs.shared.system.first(where: { $0.kind == kind }) else { return }
        TTYs.shared.move(tty, to: ttyWindow)
    }

    /// Machine > Switch to JIT… or Switch to TCTI…, asking first as Settings
    /// does.
    @objc func switchBackend(_ sender: Any?) {
        guard let running = Backend.current, !Backend.isBusy else { return }
        askToSwitch(to: running == .native ? .tcti : .native)
    }

    /// Machine > Execution Mode, which applies straight away.
    @objc func setExecutionMode(_ sender: UICommand) {
        guard let value = sender.propertyList as? String, ExecutionMode(rawValue: value) != nil
        else { return }
        AppSetting.jitMode.set(value)
        Backend.modeChanged()
    }

    /// Machine > vCPUs, which Linux is given or gives back while it runs.
    @objc func setVcpus(_ sender: UICommand) {
        guard let count = sender.propertyList as? Int else { return }
        Vcpus.foreground = count
    }

    /// View > Dark Theme, as Settings > Appearance sets it.
    @objc func setDarkTheme(_ sender: UICommand) {
        guard let id = sender.propertyList as? String else { return }
        TerminalThemes.select(id, for: .dark)
    }

    /// View > Light Theme, as Settings > Appearance sets it.
    @objc func setLightTheme(_ sender: UICommand) {
        guard let id = sender.propertyList as? String else { return }
        TerminalThemes.select(id, for: .light)
    }

    @objc func toggleKeepScreenAwake(_ sender: Any?) {
        AppSetting.keepScreenAwake.set(!AppSetting.keepScreenAwake.bool)
        ScreenAwake.apply()
    }

    /// Machine > Recovery Boot…: asks, then starts Linux again from nothing.
    @objc func confirmRecoveryBoot(_ sender: Any?) {
        confirm(
            title: "Recovery Boot?",
            message:
                "Linux starts again from scratch. Programs running in every terminal end, and anything they haven't saved to the disk is lost.",
            action: "Recovery Boot"
        ) {
            AppStatus.shared.performRecoveryBoot()
        }
    }

    /// Machine > Compact Disk…, as in Settings > Storage.
    @objc func compactDisk(_ sender: Any?) {
        confirmCompaction()
    }
}

// MARK: - Dropping a TTY from another window

extension ViewController: UIDropInteractionDelegate {

    /// The TTY a drag from a switcher carries, if it's in another window, or in
    /// none.
    private func foreignTTY(in session: UIDropSession) -> TTY? {
        guard let items = session.localDragSession?.items, items.count == 1,
            let id = items[0].localObject as? UUID, let tty = TTYs.shared.tty(id),
            !ttyWindow.contains(tty), TTYs.shared.canMove(tty)
        else { return nil }
        return tty
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession)
        -> Bool
    {
        foreignTTY(in: session) != nil
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: foreignTTY(in: session) != nil ? .move : .forbidden)
    }

    /// Moves the TTY here and selects it.
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let tty = foreignTTY(in: session) else { return }
        TTYs.shared.move(tty, to: ttyWindow)
    }
}

// MARK: - Theme

extension ViewController {

    /// Dresses what's around and over the terminal for the theme in use: the
    /// margin around it, the status bar, and the bars and buttons over it,
    /// whose glass is tinted as `OverlayGlass` works out.
    @objc fileprivate func applyTheme() {
        let theme = TerminalThemes.selected(for: TerminalThemes.Appearance(of: view))
        view.backgroundColor = theme.background.uiColor

        let style = theme.interfaceStyle
        let overlays: [UIView?] = [keyBar, keyBar?.rails, followButton, floatingSwitcher, findBar]
        for overlay in overlays {
            overlay?.overrideUserInterfaceStyle = style
        }

        glassTint = OverlayGlass.tint(for: theme)
        keyBar?.glassTint = glassTint
        followButton.glassTint = glassTint
        floatingSwitcher.glassTint = glassTint
        findBar?.glassTint = glassTint
        if style != overlayStyle {
            overlayStyle = style
            setNeedsStatusBarAppearanceUpdate()
        }
    }
}
