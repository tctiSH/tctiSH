//
//  SettingsViewController.swift
//  The in-app settings screen.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

// MARK: - The shape of a settings screen

/// What the accessory on the right of a row says about it.
private enum RowAccessory {

    /// Nothing; the row is inert.
    case none

    /// This is the chosen one of a set of options.
    case checkmark

    /// Tapping pushes another screen.
    case disclosure

    /// Tapping pushes another screen, and what is on it is the current choice.
    ///
    /// For a setting split over two screens: without the tick, which of them
    /// you are actually using can only be worked out by going into each in turn
    /// and looking.
    case selectedDisclosure
}

/// A value the user types rather than picks.
private struct EditableValue {
    var text: String
    var placeholder: String

    /// Called on every keystroke, so the setting is never left unsaved.
    var commit: (String) -> Void
}

/// A row in one of the settings lists.
private struct SettingsRow {

    /// Identity, and stable across rebuilds.
    ///
    /// Not a fresh `UUID` per build: the diffable data source would then see
    /// every row replaced on every reload and rebuild its cell, which takes the
    /// keyboard away from a field being typed into.
    var id: String

    var title: String
    var detail: String?
    var symbol: String?
    var accessory: RowAccessory = .none

    /// Set when the row carries a text field rather than a fixed value.
    var editable: EditableValue?

    /// Set when the row carries a switch.
    var toggle: ToggleValue?

    /// What tapping does, or nil if the row does nothing.
    var select: (() -> Void)?
}

/// A switch on a row.
private struct ToggleValue {
    var isOn: Bool
    var commit: (Bool) -> Void
}

/// A group of rows, with the prose that explains them.
private struct SettingsSection {
    var header: String?
    var footer: String?
    var rows: [SettingsRow]
}

/// One choice on an option screen.
private struct SettingsOption<Value: Equatable> {
    var title: String
    var value: Value
}

/// A text field that asks to be a fixed width.
///
/// A cell accessory sizes its custom view from that view's intrinsic content
/// size, and a text field's own is whatever its text happens to measure -- so
/// an empty one would collapse to nothing and a long value would crowd out the
/// title beside it. Overriding the width is how to say "this wide, whatever is
/// in you", given that the constraint route is closed: accessories require
/// `translatesAutoresizingMaskIntoConstraints` to remain enabled, and raise an
/// `NSInternalInconsistencyException` if it doesn't.
private final class FixedWidthTextField: UITextField {

    static let width: CGFloat = 150

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.width, height: super.intrinsicContentSize.height)
    }
}

/// The list plumbing, so each screen below is content only.
///
/// Internal rather than private only because `SettingsViewController` inherits
/// from it and has to be reachable from `ViewController`; a subclass cannot be
/// more visible than its superclass. Nothing outside this file should build
/// one.
///
/// A collection-view list rather than a `UITableView`: it is the current idiom
/// for this kind of screen, `UIListContentConfiguration` replaces the
/// long-deprecated `textLabel`/`detailTextLabel` pair, and standard list cells
/// pick up the system's current appearance without this file having an opinion
/// about how they should look.
class SettingsListViewController: UIViewController, UICollectionViewDelegate {

    /// Rebuilt on every appearance, so a screen always reflects what the one
    /// pushed on top of it did.
    fileprivate var sections: [SettingsSection] = []

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    /// Every row currently on screen, so the cell registration and the delegate
    /// can find one without walking `sections`.
    private var rowsById: [String: SettingsRow] = [:]

    /// The text fields, kept across rebuilds so editing survives a reload.
    private var fields: [String: UITextField] = [:]

    /// The switches, kept for the same reason: a fresh one mid-gesture would
    /// snap back under the finger moving it.
    private var switches: [String: UISwitch] = [:]

    /// Fills in `sections`. Overridden by every subclass.
    fileprivate func buildSections() -> [SettingsSection] { [] }

    // MARK: Setup

    override func viewDidLoad() {
        super.viewDidLoad()

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        makeDataSource()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    /// Builds the layout.
    ///
    /// Per-section rather than one configuration for the whole list, because
    /// `headerMode`/`footerMode` are properties of a section: asking for
    /// supplementary views list-wide would reserve space above every group.
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)

            let section = self?.sections[safe: index]
            configuration.headerMode = section?.header == nil ? .none : .supplementary
            configuration.footerMode = section?.footer == nil ? .none : .supplementary

            return NSCollectionLayoutSection.list(
                using: configuration, layoutEnvironment: environment)
        }
    }

    private func makeDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, id in
            guard let self, let row = rowsById[id] else { return }

            var content = UIListContentConfiguration.valueCell()
            content.text = row.title
            content.secondaryText = row.detail
            content.image = row.symbol.flatMap { UIImage(systemName: $0) }
            content.imageProperties.tintColor = .tintColor
            cell.contentConfiguration = content

            if let toggle = row.toggle {
                let control = self.control(for: id, toggle: toggle)
                control.isOn = toggle.isOn

                cell.accessories = [
                    .customView(configuration: .init(customView: control, placement: .trailing()))
                ]
                return
            }

            if let editable = row.editable {
                let field = field(for: id, editable: editable)
                field.text = editable.text
                field.placeholder = editable.placeholder

                cell.accessories = [
                    .customView(configuration: .init(customView: field, placement: .trailing()))
                ]
                return
            }

            switch row.accessory {
            case .none: cell.accessories = []
            case .checkmark: cell.accessories = [.checkmark()]
            case .disclosure: cell.accessories = [.disclosureIndicator()]
            case .selectedDisclosure:
                cell.accessories = [.disclosureIndicator(), .checkmark()]
            }
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.sections[safe: indexPath.section]?.header
            view.contentConfiguration = content
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = self?.sections[safe: indexPath.section]?.footer
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            let registration = kind == UICollectionView.elementKindSectionHeader ? header : footer
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: registration, for: indexPath)
        }
    }

    /// The text field for a row, made once and then kept.
    private func field(for id: String, editable: EditableValue) -> UITextField {
        if let existing = fields[id] { return existing }

        let field = FixedWidthTextField()
        field.borderStyle = .none
        field.textAlignment = .right
        field.textColor = .secondaryLabel
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done

        // These are machine names -- a disk file and a snapshot tag -- so the keyboard should not
        // be trying to be helpful about them.
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no

        // Sized by its frame and its intrinsic width, *not* by a constraint. Cell accessories
        // require `translatesAutoresizingMaskIntoConstraints` to stay on -- they throw outright if
        // it doesn't -- so the constraint route is closed off here.
        field.frame = CGRect(x: 0, y: 0, width: FixedWidthTextField.width, height: 32)

        // On every keystroke rather than when editing ends: there is no Save button here, and a
        // sheet dismissed mid-edit would otherwise quietly discard what had been typed.
        field.addAction(
            UIAction { [weak self, weak field] _ in
                guard let text = field?.text else { return }
                self?.rowsById[id]?.editable?.commit(text)
            }, for: .editingChanged)

        field.addAction(
            UIAction { [weak field] _ in field?.resignFirstResponder() },
            for: .editingDidEndOnExit)

        fields[id] = field
        return field
    }

    /// The switch for a row, made once and then kept.
    ///
    /// No sizing to arrange, unlike the text fields: a `UISwitch` has an
    /// intrinsic size of its own and leaves
    /// `translatesAutoresizingMaskIntoConstraints` alone, which is what cell
    /// accessories insist on.
    private func control(for id: String, toggle: ToggleValue) -> UISwitch {
        if let existing = switches[id] { return existing }

        let control = UISwitch()
        control.addAction(
            UIAction { [weak self, weak control] _ in
                guard let isOn = control?.isOn else { return }
                self?.rowsById[id]?.toggle?.commit(isOn)
            }, for: .valueChanged)

        switches[id] = control
        return control
    }

    // MARK: Content

    fileprivate func reload() {
        sections = buildSections()

        rowsById = [:]
        for section in sections {
            for row in section.rows {
                rowsById[row.id] = row
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        for (index, section) in sections.enumerated() {
            snapshot.appendSections([index])
            snapshot.appendItems(section.rows.map(\.id), toSection: index)
        }

        // Rows that already exist are reconfigured rather than left as they were, so their content
        // catches up: a checkmark that moved, a value chosen on the screen above. A row being typed
        // into is skipped, because reconfiguring rebuilds its accessories and that would take the
        // keyboard away mid-word.
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let refresh = snapshot.itemIdentifiers.filter {
            existing.contains($0) && fields[$0]?.isFirstResponder != true
        }
        if !refresh.isEmpty {
            snapshot.reconfigureItems(refresh)
        }

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: Selection

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        rowsById[id]?.select?()
    }

    func collectionView(
        _ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath
    ) -> Bool {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return false }
        return rowsById[id]?.select != nil
    }

    // MARK: Navigation helpers

    fileprivate func push(_ controller: UIViewController) {
        navigationController?.pushViewController(controller, animated: true)
    }

    /// Returns to the first screen of the sheet.
    ///
    /// Used once a value has actually been chosen. Popping a single level would
    /// land someone back on the list they just came through, which invites them
    /// to make the same choice again; the root is where they can see what it
    /// came to.
    fileprivate func popToRoot() {
        guard let navigation = navigationController, let root = navigation.viewControllers.first
        else {
            return
        }

        navigation.popToViewController(root, animated: true)
    }
}

extension Array {
    /// The element at `index`, or nil if there isn't one.
    ///
    /// The layout's section provider can be asked about a section that the
    /// snapshot no longer has, during the window between `sections` changing
    /// and the apply landing.
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - A screen that picks one of a fixed list

/// The screen behind every setting that is a choice from a fixed list.
private final class OptionListViewController<Value: Equatable>: SettingsListViewController {

    private let screenTitle: String
    private let footer: String?
    private let options: [SettingsOption<Value>]
    private let selected: () -> Value
    private let choose: (Value) -> Void

    init(
        title: String,
        footer: String? = nil,
        options: [SettingsOption<Value>],
        selected: @escaping () -> Value,
        choose: @escaping (Value) -> Void
    ) {
        self.screenTitle = title
        self.footer = footer
        self.options = options
        self.selected = selected
        self.choose = choose

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; these screens are built in code")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = screenTitle
        navigationItem.largeTitleDisplayMode = .never
    }

    fileprivate override func buildSections() -> [SettingsSection] {
        let current = selected()

        return [
            SettingsSection(
                header: nil,
                footer: footer,
                rows: options.enumerated().map { index, option in
                    SettingsRow(
                        id: "option-\(index)",
                        title: option.title,
                        accessory: option.value == current ? .checkmark : .none,
                        select: { [weak self] in
                            self?.choose(option.value)
                            self?.popToRoot()
                        })
                })
        ]
    }
}

// MARK: - Root

/// The settings sheet's first screen.
///
/// Everything the app lets the user change is here, with only the OS-level
/// settings living within the app's portion of the settings app.
final class SettingsViewController: SettingsListViewController,
    UIAdaptivePresentationControllerDelegate, UIGestureRecognizerDelegate
{

    /// The settings whose changes cost something, as they were on entry.
    ///
    /// Captured so the warning on the way out is about what actually changed,
    /// rather than firing on every dismissal.
    private struct Entry {
        let memory = VmMemory.selected
        let codeCache = CodeCache.bootSignature
        let diskName = AppSetting.diskName.string
        let jitMode = AppSetting.jitMode.string
        let resumeBehavior = AppSetting.resumeBehavior.string
        let bootSnapshot = AppSetting.bootSnapshot.string
    }

    private let onEntry = Entry()

    /// Whether three taps on the title have brought up the debug tools.
    ///
    /// For the life of the process rather than saved: they're for testing
    /// tctiSH, and shouldn't still be sitting there the next time someone opens
    /// Settings for the usual reasons.
    private static var debugToolsRevealed = false

    /// Puts the settings sheet up over whatever is on screen.
    static func present(from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: SettingsViewController())
        navigation.navigationBar.prefersLargeTitles = true

        // A sheet rather than a full-screen presentation: the terminal stays visible behind it,
        // which matters because the numbers being chosen here are about the thing running in it.
        navigation.modalPresentationStyle = .formSheet
        navigation.sheetPresentationController?.prefersGrabberVisible = true

        // The grabber invites a swipe, and a swipe is a dismissal like any other -- so the warning
        // has to be reachable from it as well as from Done. Set on the navigation controller's
        // presentation because that is what the gesture acts on; the delegate is held weakly, and
        // the root outlives the sheet.
        let root = navigation.viewControllers.first as? SettingsViewController
        navigation.presentationController?.delegate = root

        presenter.present(navigation, animated: true)
    }

    // MARK: Being dismissed

    /// Whether a swipe may simply take the sheet away.
    ///
    /// Only when there is nothing to say. Returning false here is what turns
    /// the gesture into `presentationControllerDidAttemptToDismiss`, which is
    /// where the same alert the Done button raises gets its chance.
    func presentationControllerShouldDismiss(_ controller: UIPresentationController) -> Bool {
        consequences() == nil
    }

    func presentationControllerDidAttemptToDismiss(_ controller: UIPresentationController) {
        done()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Settings"
        navigationItem.largeTitleDisplayMode = .automatic
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.done() })

        // On the bar rather than on a title view of our own, as the large title isn't a view we get
        // to supply. The bar is shared with every screen pushed over this one, hence the check in
        // `revealDebugTools`.
        let reveal = UITapGestureRecognizer(target: self, action: #selector(revealDebugTools))
        reveal.numberOfTapsRequired = 3
        reveal.cancelsTouchesInView = false
        reveal.delegate = self
        navigationController?.navigationBar.addGestureRecognizer(reveal)
    }

    @objc private func revealDebugTools() {
        guard navigationController?.topViewController === self, !Self.debugToolsRevealed else {
            return
        }

        Log.ui.note("settings: debug tools revealed")
        Self.debugToolsRevealed = true
        reload()
    }

    /// Keeps the taps off the bar's buttons, so Done is never held up waiting
    /// to see whether a second and third tap are coming.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool
    {
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    fileprivate override func buildSections() -> [SettingsSection] {
        var sections = [
            SettingsSection(
                header: "Virtual Machine",
                footer:
                    "Properties of the virtual machine. VM Memory sets how much RAM is given to Linux. Code Cache determines how much memory is used to hold translated x86_64 code.",
                rows: [
                    SettingsRow(
                        id: "memory",
                        title: "VM Memory",
                        detail: Mebibytes.describe(VmMemory.selected),
                        symbol: "memorychip",
                        accessory: .disclosure,
                        select: { [weak self] in self?.push(VmMemoryViewController()) }),
                    SettingsRow(
                        id: "code-cache",
                        title: "Code Cache",
                        detail: CodeCache.summary,
                        symbol: "cpu",
                        accessory: .disclosure,
                        select: { [weak self] in self?.push(CodeCacheViewController()) }),
                ]),

            SettingsSection(
                header: "Startup",
                footer:
                    "How your terminal environment is executed, and what it does when you close the app.",
                rows: [
                    SettingsRow(
                        id: "resume",
                        title: "On App Close",
                        detail: Self.label(Self.resumeOptions, for: .resumeBehavior),
                        symbol: "arrow.clockwise",
                        accessory: .disclosure,
                        select: { [weak self] in self?.pushResumeBehavior() }),
                    SettingsRow(
                        id: "jit",
                        title: "Execution Mode",
                        detail: Self.label(Self.jitOptions, for: .jitMode),
                        symbol: "bolt",
                        accessory: .disclosure,
                        select: { [weak self] in self?.pushJitMode() }),
                ]),

            SettingsSection(
                header: "Storage",
                footer:
                    "Where your session is stored, including the disk image and boot snapshot (used for resume) file names. A disk name that doesn't yet exist creates a fresh machine.",
                rows: [
                    SettingsRow(
                        id: "disk-name",
                        title: "Disk Name",
                        symbol: "internaldrive",
                        editable: EditableValue(
                            text: AppSetting.diskName.string,
                            placeholder: "disk",
                            commit: { AppSetting.diskName.set($0) })),
                    SettingsRow(
                        id: "boot-snapshot",
                        title: "Boot Snapshot",
                        symbol: "camera",
                        editable: EditableValue(
                            text: AppSetting.bootSnapshot.string,
                            placeholder: "none",
                            commit: { AppSetting.bootSnapshot.set($0) })),
                ]),

            SettingsSection(
                header: "Appearance",
                footer: nil,
                rows: [
                    SettingsRow(
                        id: "font-size",
                        title: "Font Size",
                        detail: "\(AppSetting.fontSize.integer)",
                        symbol: "textformat.size",
                        accessory: .disclosure,
                        select: { [weak self] in self?.pushFontSize() })
                ]),

            SettingsSection(
                header: nil,
                footer:
                    "Permissions are under the control of the operating system, so they live in the Settings app.",
                rows: [
                    SettingsRow(
                        id: "ios-settings",
                        title: "tctiSH in iOS Settings",
                        symbol: "gearshape",
                        accessory: .disclosure,
                        select: { Self.openSystemSettings() })
                ]),
        ]

        if Self.debugToolsRevealed {
            sections.append(
                SettingsSection(
                    header: nil,
                    footer: nil,
                    rows: [
                        SettingsRow(
                            id: "debug-tools",
                            title: "Debug Tools",
                            symbol: "ladybug",
                            accessory: .disclosure,
                            select: { [weak self] in self?.push(DebugToolsViewController()) })
                    ]))
        }

        return sections
    }

    // MARK: The fixed choices

    private static let resumeOptions = [
        SettingsOption(title: "Save Linux State", value: "persistent_boot"),
        SettingsOption(title: "Recovery Boot", value: "recovery_boot"),
        SettingsOption(title: "Boot From Snapshot", value: "snapshot_boot"),
        SettingsOption(title: "Reboot", value: "clean_boot"),
    ]

    fileprivate static let jitOptions = [
        SettingsOption(title: "JIT When Possible", value: "jit_when_possible"),
        SettingsOption(title: "Never JIT", value: "never_jit"),
    ]

    private static let fontSizes = [8, 10, 12, 14, 16, 18, 20, 22, 24, 28, 30]

    /// The label for whatever `setting` currently holds.
    ///
    /// Falls back to the stored value itself, so a setting left holding
    /// something this build no longer offers shows what it is rather than
    /// showing nothing.
    fileprivate static func label(_ options: [SettingsOption<String>], for setting: AppSetting)
        -> String
    {
        let value = setting.string
        return options.first { $0.value == value }?.title ?? value
    }

    private func pushResumeBehavior() {
        push(
            OptionListViewController(
                title: "On Close",
                footer: "Persist Linux State picks the session up where you left it. Recovery "
                    + "Boot and Clean Reboot both start Linux again from nothing. Boot From Snapshot loads the snapshot named under "
                    + "Storage.",
                options: Self.resumeOptions,
                selected: { AppSetting.resumeBehavior.string },
                choose: { AppSetting.resumeBehavior.set($0) }))
    }

    private func pushJitMode() {
        push(
            OptionListViewController(
                title: "JIT Mode",
                footer:
                    "JIT is much faster, but needs external support from a loopback VPN and may not always be available. Turning off JIT will be slower but should always work.",
                options: Self.jitOptions,
                selected: { AppSetting.jitMode.string },
                choose: { AppSetting.jitMode.set($0) }))
    }

    private func pushFontSize() {
        push(
            OptionListViewController(
                title: "Font Size",
                footer: "Applies straight away.",
                options: Self.fontSizes.map { SettingsOption(title: "\($0)", value: $0) },
                selected: { AppSetting.fontSize.integer },
                choose: { AppSetting.fontSize.set($0) }))
    }

    /// Opens this app's own page in the Settings app.
    private static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Leaving

    /// Says what the changes will cost, on the way out.
    ///
    /// On dismissal rather than on each row: someone stepping through a ladder
    /// to see what is on offer should not be warned once per tap, and what
    /// matters is the change they settled on.
    private func done() {
        guard let message = consequences() else {
            dismiss(animated: true)
            return
        }

        let alert = UIAlertController(
            title: "Restart Needed", message: message, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.dismiss(animated: true)
            })

        // From the navigation controller, because a swipe can be answered while a sub-screen is
        // pushed and this one is covered by it.
        (navigationController ?? self).present(alert, animated: true)
    }

    /// What to say about what changed.
    private func consequences() -> String? {
        if VmMemory.selected != onEntry.memory {
            return
                "Linux will start again from scratch the next time you open tctiSH. Anything in the resumed session is lost."
        }

        if AppSetting.diskName.string != onEntry.diskName {
            return
                "tctiSH will use a different disk image the next time you open it. The session you have now is untouched, and "
                + "stays on the disk it is already using."
        }

        var waiting: [String] = []
        if CodeCache.bootSignature != onEntry.codeCache { waiting.append("code cache size") }
        if AppSetting.jitMode.string != onEntry.jitMode { waiting.append("JIT mode") }
        if AppSetting.resumeBehavior.string != onEntry.resumeBehavior {
            waiting.append("close behaviour")
        }
        if AppSetting.bootSnapshot.string != onEntry.bootSnapshot {
            waiting.append("boot snapshot")
        }

        guard !waiting.isEmpty else { return nil }

        return "The new \(Self.list(waiting)) takes effect the next time you open tctiSH. Your "
            + "resumed session is not affected."
    }

    /// Joins names the way a sentence would.
    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }
}

// MARK: - Debug tools

extension UIViewController {

    /// Shows an alert from this controller, or from whatever it is already
    /// showing.
    fileprivate func showAlert(title: String, message: String) {
        var top: UIViewController = self
        while let presented = top.presentedViewController {
            top = presented
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }

    /// Asks before doing something that can't be taken back.
    fileprivate func confirm(
        title: String, message: String, action: String, _ perform: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .destructive) { _ in perform() })
        present(alert, animated: true)
    }

    /// Offers files through the share sheet, anchored to `item` on iPad.
    fileprivate func share(_ files: [URL], from item: UIBarButtonItem?) {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            showAlert(title: "Nothing to Share", message: "There are no log files yet.")
            return
        }

        let sheet = UIActivityViewController(activityItems: existing, applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = item
        present(sheet, animated: true)
    }
}

/// When something happened, for a row's detail.
private let debugTimeFormat: DateFormatter = {
    let format = DateFormatter()
    format.dateStyle = .medium
    format.timeStyle = .medium
    return format
}()

/// Tools for testing tctiSH itself, behind three taps on the Settings title.
private final class DebugToolsViewController: SettingsListViewController {

    /// Set while a removal is under way, so it can't be started twice.
    ///
    /// Static rather than per screen: a removal outlives the screen that
    /// started it if someone goes back, and one opened afresh mustn't offer to
    /// start another.
    private static var removing = false

    /// The Debug Tools screen on show, which is where a removal reports back.
    ///
    /// Not necessarily the one that started it, for the same reason.
    private static weak var onScreen: DebugToolsViewController?

    /// When a memory warning was last simulated, this process.
    private static var lastMemoryWarning: Date?

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Debug Tools"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Self.onScreen = self
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if Self.onScreen === self { Self.onScreen = nil }
    }

    fileprivate override func buildSections() -> [SettingsSection] {
        let hasPairingFile = JitPairingFile.exists

        return [
            SettingsSection(
                header: "JIT",
                footer: "Deleting the pairing file makes the next launch run without JIT and ask "
                    + "for a new one. Until then the code cache can't grow.",
                rows: [
                    SettingsRow(
                        id: "jit-status",
                        title: "JIT Status",
                        symbol: "bolt",
                        accessory: .disclosure,
                        select: { [weak self] in self?.push(JitStatusViewController()) }),
                    SettingsRow(
                        id: "delete-pairing",
                        title: "Delete Pairing File",
                        detail: hasPairingFile ? nil : "None",
                        symbol: "key",
                        select: hasPairingFile
                            ? { [weak self] in self?.confirmPairingDeletion() } : nil),
                ]),

            SettingsSection(
                header: "Developer Disk Image",
                footer:
                    "Uninstalls every DDI from this device and deletes tctiSH's downloaded copy, "
                    + "so the next launch has to fetch and mount one itself, and starts without JIT "
                    + "while it does. Rebooting isn't enough on its own: an installed DDI comes back "
                    + "at every boot.",
                rows: [
                    SettingsRow(
                        id: "remove-ddis",
                        title: "Remove All DDIs",
                        detail: Self.removing ? "Removing…" : nil,
                        symbol: "trash",
                        select: Self.removing ? nil : { [weak self] in self?.confirmRemoval() })
                ]),

            SettingsSection(
                header: "Virtual Machine",
                footer: "A simulated warning is the one UIKit posts under real pressure, so tctiSH "
                    + "responds as it would to that: any pending code cache expansion is called "
                    + "off, and a Dynamic cache above what a warning allows is shrunk. The "
                    + "system's own pressure level is untouched.",
                rows: [
                    SettingsRow(
                        id: "saved-sessions",
                        title: "Saved Sessions",
                        symbol: "camera",
                        accessory: .disclosure,
                        select: { [weak self] in self?.push(SavedSessionsViewController()) }),
                    SettingsRow(
                        id: "memory-warning",
                        title: "Simulate Memory Warning",
                        detail: Self.lastMemoryWarning.map {
                            "Sent \(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium))"
                        },
                        symbol: "memorychip",
                        select: { [weak self] in self?.simulateMemoryWarning() }),
                ]),

            SettingsSection(
                header: nil,
                footer: nil,
                rows: [
                    SettingsRow(
                        id: "logs",
                        title: "Logs",
                        symbol: "doc.text",
                        accessory: .disclosure,
                        select: { [weak self] in self?.push(LogsViewController()) })
                ]),
        ]
    }

    // MARK: Pairing file

    private func confirmPairingDeletion() {
        confirm(
            title: "Delete Pairing File?",
            message: "JIT keeps working until tctiSH is closed. The next launch runs without it, "
                + "and asks for a new pairing file.",
            action: "Delete"
        ) { [weak self] in
            do {
                try FileManager.default.removeItem(at: JitPairingFile.url)
                Log.fs.note("debug: deleted the pairing file")
            } catch {
                self?.showAlert(
                    title: "Couldn't Delete Pairing File", message: error.localizedDescription)
            }

            self?.reload()
        }
    }

    // MARK: Memory

    private func simulateMemoryWarning() {
        Log.ui.note("debug: simulating a memory warning")
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)

        Self.lastMemoryWarning = Date()
        reload()
    }

    // MARK: Removing DDIs

    private func confirmRemoval() {
        confirm(
            title: "Remove All DDIs?",
            message: "JIT keeps working until tctiSH is closed, though the code cache can't grow "
                + "any further. The launch after that starts without JIT, while the DDI is "
                + "downloaded and mounted again.",
            action: "Remove"
        ) { [weak self] in
            self?.removeAll()
        }
    }

    private func removeAll() {
        // Removing goes through the same tunnel as JIT, so it needs the same pairing file.
        guard let pairingData = JitPairingFile.read() else {
            showAlert(
                title: "No Pairing File", message: "Removing a DDI needs the pairing file JIT uses."
            )
            return
        }

        Self.removing = true
        reload()

        // The fallback for reporting, if nobody is on a Debug Tools screen by the time this
        // finishes but the settings sheet is still up.
        weak var sheet = navigationController

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DdiPreparation.removeAll(pairingData: pairingData)

            DispatchQueue.main.async {
                Self.removing = false
                Self.onScreen?.reload()

                let (title, message) =
                    switch outcome {
                    case .removed(let message): ("DDIs Removed", message)
                    case .failed(let reason): ("Couldn't Remove DDIs", reason)
                    }

                // With the sheet gone too there is nobody to tell, and the outcome is in the log.
                guard let presenter = Self.onScreen ?? sheet, presenter.viewIfLoaded?.window != nil
                else {
                    return
                }

                presenter.showAlert(title: title, message: message)
            }
        }
    }
}

// MARK: - Debug tools: JIT status

/// Everything JIT depends on, checked afresh each time the screen appears.
private final class JitStatusViewController: SettingsListViewController {

    /// What the checks that need the device found, or nil while they run.
    private struct DeviceChecks {
        var tunnel: String
        var ddi: String
    }

    private var checks: DeviceChecks?
    private var checking = false

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "JIT Status"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.check() })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        check()
    }

    /// Runs the checks that go to the device. Both can take seconds, the tunnel
    /// probe's timeout especially, so off the main thread.
    private func check() {
        guard !checking else { return }
        checking = true
        checks = nil
        reload()

        let pairingData = JitPairingFile.read()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let probe = TunnelProbe.probeAndReport()

            let tunnel: String
            switch probe {
            case .available(let elapsed):
                tunnel = String(format: "Connected (%.0f ms)", elapsed * 1000)
            case .unavailable:
                tunnel = "Not connected"
            }

            let ddi: String
            if !probe.isAvailable {
                ddi = "Unknown: no tunnel"
            } else if let pairingData {
                do {
                    ddi =
                        try DdiPreparation.isMounted(pairingData: pairingData)
                        ? "Mounted" : "Not mounted"
                } catch {
                    ddi = "Unknown: \(error.localizedDescription)"
                }
            } else {
                ddi = "Unknown: no pairing file"
            }

            DispatchQueue.main.async {
                self?.checks = DeviceChecks(tunnel: tunnel, ddi: ddi)
                self?.checking = false
                self?.reload()
            }
        }
    }

    fileprivate override func buildSections() -> [SettingsSection] {
        let cache: String
        switch DdiPreparation.cacheState {
        case .complete: cache = "Complete"
        case .partial: cache = "Partial"
        case .none: cache = "None"
        }

        return [
            SettingsSection(
                header: "This Launch",
                footer: nil,
                rows: [
                    SettingsRow(
                        id: "outcome",
                        title: "JIT",
                        detail: JitEnablement.outcome?.status.message ?? "Deciding…"),
                    SettingsRow(
                        id: "mode",
                        title: "Execution Mode",
                        detail: SettingsViewController.label(
                            SettingsViewController.jitOptions, for: .jitMode)),
                ]),

            SettingsSection(
                header: "Requirements",
                footer: "Under TXM, JIT needs all of these: the loopback VPN for a tunnel to the "
                    + "device, the pairing file to authenticate it, and a mounted DDI for the "
                    + "debugger. Without TXM, it needs none of them.",
                rows: [
                    SettingsRow(
                        id: "txm", title: "TXM", detail: TxmPresence.current.description.capitalized
                    ),
                    SettingsRow(
                        id: "tunnel", title: "Loopback VPN", detail: checks?.tunnel ?? "Checking…"),
                    SettingsRow(
                        id: "pairing",
                        title: "Pairing File",
                        detail: JitPairingFile.exists ? "Present" : "Missing"),
                    SettingsRow(id: "ddi", title: "DDI", detail: checks?.ddi ?? "Checking…"),
                    SettingsRow(id: "cache", title: "Downloaded DDI", detail: cache),
                ]),
        ]
    }
}

// MARK: - Debug tools: saved sessions

/// Each disk's saved session, and the snapshots on the one that's running.
private final class SavedSessionsViewController: SettingsListViewController {

    /// The running disk's snapshots, or nil while they're being listed.
    private var snapshots: [String]?

    /// Set when the monitor didn't answer.
    private var listingFailed = false

    /// Which listing is the latest. Two can be in flight, from a refresh
    /// straight after a delete, and the one asked first can answer last.
    private var listing = 0

    private var qemu: QEMUInterface? {
        (UIApplication.shared.delegate as? AppDelegate)?.qemu
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Saved Sessions"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.listSnapshots() })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        listSnapshots()
    }

    /// Asks the monitor, which can take seconds, so off the main thread.
    private func listSnapshots() {
        guard let qemu else { return }

        snapshots = nil
        listingFailed = false
        listing += 1
        reload()

        let asked = listing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tags = qemu.snapshotsOnRunningDisk()

            DispatchQueue.main.async {
                guard let self, self.listing == asked else { return }

                self.snapshots = tags ?? []
                self.listingFailed = tags == nil
                self.reload()
            }
        }
    }

    fileprivate override func buildSections() -> [SettingsSection] {
        guard let qemu else {
            return [
                SettingsSection(
                    header: nil,
                    footer: nil,
                    rows: [SettingsRow(id: "no-vm", title: "The VM isn't running")])
            ]
        }

        let sessions = qemu.savedSessions()
        var sections = sessions.map(section(for:))

        if let running = sessions.first(where: \.isRunning) {
            sections.append(snapshotSection(for: running))
        }

        let lastSaved = QEMUInterface.lastSavedAt
        let lastFailed = QEMUInterface.lastSaveFailedAt

        // Whichever happened later. A save that ran out of time and then finished anyway only
        // records its success, so this doesn't call that one a failure.
        let lastAttempt: String
        if let lastFailed, lastSaved.map({ lastFailed > $0 }) ?? true {
            lastAttempt = "Failed \(debugTimeFormat.string(from: lastFailed))"
        } else {
            lastAttempt = lastSaved == nil ? "–" : "Succeeded"
        }

        sections.append(
            SettingsSection(
                header: "Saving",
                footer: "A saved session is resumed only if the machine that saved it had this "
                    + "stamp, which is what the next launch will build: "
                    + QEMUInterface.wantedStamp,
                rows: [
                    SettingsRow(
                        id: "last-saved",
                        title: "Last Saved",
                        detail: lastSaved.map { debugTimeFormat.string(from: $0) } ?? "Never"),
                    SettingsRow(
                        id: "last-attempt",
                        title: "Last Attempt",
                        detail: lastAttempt),
                ]))

        return sections
    }

    private func section(for session: QEMUInterface.SavedSession) -> SettingsSection {
        let hasSession = !session.tag.isEmpty

        let machine: String
        if !hasSession {
            machine = "–"
        } else if session.stampMatches {
            machine = "Matches"
        } else {
            machine = session.stamp.isEmpty ? "Unstamped" : "Different"
        }

        var notes: [String] = []
        if hasSession && !session.stampMatches {
            notes.append(
                session.stamp.isEmpty
                    ? "Saved before stamps were recorded, so it won't be resumed."
                    : "Saved as \(session.stamp), so it won't be resumed.")
        }
        if session.isRunning {
            notes.append("Leaving tctiSH saves this disk's session again, replacing this one.")
        }

        var rows = [
            SettingsRow(
                id: "session-\(session.disk)",
                title: "Saved Session",
                detail: hasSession ? session.tag : "None"),
            SettingsRow(id: "machine-\(session.disk)", title: "Machine", detail: machine),
        ]

        if hasSession {
            rows.append(
                SettingsRow(
                    id: "forget-\(session.disk)",
                    title: "Forget Saved Session",
                    symbol: "xmark.circle",
                    select: { [weak self] in self?.confirmForgetting(session.disk) }))
        }

        return SettingsSection(
            header: session.isRunning ? "\(session.disk) (running)" : session.disk,
            footer: notes.isEmpty ? nil : notes.joined(separator: " "),
            rows: rows)
    }

    private func snapshotSection(for running: QEMUInterface.SavedSession) -> SettingsSection {
        let rows: [SettingsRow]

        if let snapshots, !listingFailed {
            rows =
                snapshots.isEmpty
                ? [SettingsRow(id: "snapshots-none", title: "None")]
                : snapshots.map { tag in
                    SettingsRow(
                        id: "snapshot-\(tag)",
                        title: tag,
                        detail: tag == running.tag ? "Saved session" : nil,
                        select: { [weak self] in
                            self?.confirmDeleting(tag, onRunningDisk: running.disk)
                        })
                }
        } else {
            let title = listingFailed ? "The monitor didn't answer" : "Checking…"
            rows = [SettingsRow(id: "snapshots-pending", title: title)]
        }

        return SettingsSection(
            header: "Snapshots on \(running.disk)",
            footer: "Tap one to delete it.",
            rows: rows)
    }

    private func confirmForgetting(_ disk: String) {
        confirm(
            title: "Forget Saved Session?",
            message: "The next launch on '\(disk)' cold boots. The snapshot stays on the disk.",
            action: "Forget"
        ) { [weak self] in
            if let failure = self?.qemu?.forgetSavedSession(disk: disk) {
                self?.showAlert(title: "Couldn't Forget Saved Session", message: failure)
            }
            self?.reload()
        }
    }

    private func confirmDeleting(_ tag: String, onRunningDisk disk: String) {
        guard let qemu else { return }

        confirm(
            title: "Delete Snapshot?",
            message: "'\(tag)' is removed from '\(disk)'. If it's the saved session, the next "
                + "launch cold boots unless tctiSH saves again first.",
            action: "Delete"
        ) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let failure = qemu.deleteSnapshot(tag, onRunningDisk: disk)

                DispatchQueue.main.async {
                    if let failure {
                        self?.showAlert(title: "Couldn't Delete Snapshot", message: failure)
                    }
                    self?.listSnapshots()
                }
            }
        }
    }
}

// MARK: - Debug tools: logs

/// The launches whose logs are kept.
private final class LogsViewController: SettingsListViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Logs"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.shareAll() })
    }

    fileprivate override func buildSections() -> [SettingsSection] {
        [
            SettingsSection(
                header: nil,
                footer: "The last few launches. Each has tctiSH's own log, and whatever was "
                    + "written to stderr, which is where QEMU says why it stopped. Stderr isn't "
                    + "captured when Xcode launched tctiSH, as its console is reading it.",
                rows: LogFile.launches().map { launch in
                    SettingsRow(
                        id: "launch-\(launch.log.lastPathComponent)",
                        title: debugTimeFormat.string(from: launch.started),
                        detail: launch.isCurrent
                            ? "This launch"
                            : (Self.hasOutput(launch.stderr) ? "Has stderr" : nil),
                        accessory: .disclosure,
                        select: { [weak self] in self?.push(LogViewerViewController(launch: launch))
                        })
                })
        ]
    }

    /// Whether either part of `file` has anything in it.
    private static func hasOutput(_ file: URL) -> Bool {
        [file, LogFile.older(file)].contains { part in
            let size =
                (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int
            return (size ?? 0) > 0
        }
    }

    private func shareAll() {
        share(
            LogFile.launches().flatMap(\.files),
            from: navigationItem.rightBarButtonItem)
    }
}

/// One launch's log and stderr, as text.
private final class LogViewerViewController: UIViewController {

    private let launch: LogFile.Launch
    private let textView = UITextView()

    init(launch: LogFile.Launch) {
        self.launch = launch
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; these screens are built in code")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = launch.isCurrent ? "This Launch" : debugTimeFormat.string(from: launch.started)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.shareLaunch() })

        view.backgroundColor = .systemBackground

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        textView.text =
            Self.titled("tctiSH", contents: launch.log) + "\n\n"
            + Self.titled("stderr", contents: launch.stderr)

        // The end is where a launch that went wrong says so.
        textView.layoutIfNeeded()
        textView.scrollRangeToVisible(NSRange(location: textView.text.utf16.count, length: 0))
    }

    /// How much of each file is shown. A text view slows to a crawl well before
    /// a file reaches its cap, and sharing has the whole of it.
    private static let shownBytes = 256 << 10

    /// A file's text under a heading, its older part first if it was rotated.
    private static func titled(_ title: String, contents file: URL) -> String {
        let parts = [LogFile.older(file), file].compactMap { try? Data(contentsOf: $0) }
        guard !parts.isEmpty else { return "── \(title) ──\n(not captured)" }

        let whole = parts.reduce(Data(), +)
        let dropped = whole.count > shownBytes

        // Decoding repairs a character split at the cut, rather than failing on it.
        let text = String(decoding: whole.suffix(shownBytes), as: UTF8.self)

        // A rotated file is past its cap, which is well past this, so this covers rotation too.
        let note =
            dropped
            ? "(earlier output isn't shown here; share the files for all that was kept)\n" : ""

        return "── \(title) ──\n\(note)\(text.isEmpty ? "(empty)" : text)"
    }

    private func shareLaunch() {
        share(launch.files, from: navigationItem.rightBarButtonItem)
    }
}

// MARK: - Guest RAM

/// Picks how much RAM the guest gets.
private final class VmMemoryViewController: SettingsListViewController {

    /// Says what the boundary allows for, and what it would be otherwise.
    ///
    /// The code cache is only resident up front when it is blessed, so the two
    /// arrangements can put this boundary several rungs apart. Naming both
    /// stops the screen reading as though the device were simply smaller than
    /// it is.
    private static var ceilingFooter: String? {
        let blessed = VmMemory.recommendedCeiling(blessed: true)
        let unblessed = VmMemory.recommendedCeiling(blessed: false)

        guard blessed != unblessed else { return nil }

        if CodeCache.blessingExpected {
            return "Allows for the code cache, which JIT prepares in full before Linux starts. "
                + "With JIT off that memory isn't taken up front, and up to "
                + "\(Mebibytes.describe(unblessed)) would be safe."
        }

        return "JIT isn't in use. With JIT "
            + "it is prepared in full before Linux starts, which would bring this down to "
            + "\(Mebibytes.describe(blessed))."
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "VM Memory"
        navigationItem.largeTitleDisplayMode = .never
    }

    fileprivate override func buildSections() -> [SettingsSection] {
        var sections = [
            SettingsSection(
                header: "Recommended for this device",
                footer: Self.ceilingFooter,
                rows: VmMemory.recommended.map { size in
                    SettingsRow(
                        id: "size-\(size)",
                        title: Mebibytes.describe(size),
                        accessory: size == VmMemory.selected ? .checkmark : .none,
                        select: { [weak self] in
                            VmMemory.selected = size
                            self?.popToRoot()
                        })
                })
        ]

        // A device large enough that every amount we offer is recommended has nothing to put behind
        // an overflow, and an empty screen at the end of a disclosure is worse than no disclosure
        // at all.
        let beyond = VmMemory.beyondRecommended
        guard !beyond.isEmpty else { return sections }

        sections.append(
            SettingsSection(
                header: nil,
                footer: "Amounts above \(Mebibytes.describe(VmMemory.recommendedCeiling)) are "
                    + "more than this device can comfortably spare, allowing for iOS, tctiSH "
                    + "itself, and the code cache. They may result in the app being killed.",
                rows: [
                    SettingsRow(
                        id: "overflow",
                        title: "Higher Amounts",
                        detail: beyond.contains(VmMemory.selected)
                            ? Mebibytes.describe(VmMemory.selected) : nil,
                        symbol: "exclamationmark.triangle",
                        accessory: beyond.contains(VmMemory.selected)
                            ? .selectedDisclosure : .disclosure,
                        select: { [weak self] in
                            self?.push(VmMemoryOverflowViewController())
                        })
                ]))

        return sections
    }
}

/// The amounts that are on offer but not advisable.
private final class VmMemoryOverflowViewController: SettingsListViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Higher Amounts"
        navigationItem.largeTitleDisplayMode = .never
    }

    fileprivate override func buildSections() -> [SettingsSection] {
        [
            SettingsSection(
                header: "May Crash",
                footer: "iOS kills apps that ask for more memory than it can provide. "
                    + "Anything here is beyond what this device is expected to allow, so tctiSH "
                    + "may be terminated without warning in use.",
                rows: VmMemory.beyondRecommended.map { size in
                    SettingsRow(
                        id: "size-\(size)",
                        title: Mebibytes.describe(size),
                        accessory: size == VmMemory.selected ? .checkmark : .none,
                        select: { [weak self] in
                            VmMemory.selected = size
                            self?.popToRoot()
                        })
                })
        ]
    }
}

// MARK: - Code cache

/// Picks how the code cache is sized.
private final class CodeCacheViewController: SettingsListViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Code Cache"
        navigationItem.largeTitleDisplayMode = .never
    }

    fileprivate override func buildSections() -> [SettingsSection] {
        let mode = CodeCache.mode

        return [
            SettingsSection(
                header: nil,
                footer: "A bigger cache means less re-translation, whether Linux runs under JIT "
                    + "or through the interpreter. Under JIT tctiSH must also prepare every page "
                    + "before Linux starts, so a bigger cache then means a longer launch and "
                    + "that much of this device's memory held for the whole session; without JIT "
                    + "it costs only what gets used.",
                rows: [
                    SettingsRow(
                        id: "fixed",
                        title: "Fixed",
                        detail: mode == .fixed ? CodeCache.summary : nil,
                        accessory: mode == .fixed ? .selectedDisclosure : .disclosure,
                        select: { [weak self] in self?.pushLadder(for: .fixed) }),
                    SettingsRow(
                        id: "dynamic",
                        title: "Dynamic",
                        detail: mode == .dynamic ? CodeCache.summary : nil,
                        accessory: mode == .dynamic ? .selectedDisclosure : .disclosure,
                        select: { [weak self] in self?.pushLadder(for: .dynamic) }),
                ]),
            offersSection,
            notificationsSection,
        ].compactMap { $0 }
    }

    private func pushLadder(for mode: CodeCache.Mode) {
        push(CodeCacheSizeViewController(mode: mode))
    }

    /// The per-session switch for whether expansions are offered at all.
    ///
    /// Only shown under Dynamic, because nothing else ever grows. Its value
    /// lives in the monitor rather than in defaults: it is about this session,
    /// and it comes back on by itself at the next launch.
    fileprivate var offersSection: SettingsSection? {
        guard CodeCache.mode == .dynamic else { return nil }

        return SettingsSection(
            header: nil,
            footer: "Stopping an expansion turns this off, so you are not asked again while you "
                + "are busy. It comes back on the next time tctiSH starts, or right away if you toggle it here.",
            rows: [
                SettingsRow(
                    id: "cache-offers",
                    title: "Offer To Grow",
                    toggle: ToggleValue(
                        isOn: CodeCacheMonitor.offersEnabled,
                        commit: { CodeCacheMonitor.offersEnabled = $0 }))
            ])
    }

    /// The notifications switch, and what turning it off actually does.
    fileprivate var notificationsSection: SettingsSection {
        SettingsSection(
            header: nil,
            footer: "Before growing the cache tctiSH shows a short countdown you can tap to "
                + "stop, and says so afterwards when it grows or gives memory back under "
                + "pressure. With this off it does all of that silently.",
            rows: [
                SettingsRow(
                    id: "cache-notifications",
                    title: "Size Notifications",
                    toggle: ToggleValue(
                        isOn: AppSetting.codeCacheNotifications.bool,
                        commit: { AppSetting.codeCacheNotifications.set($0) }))
            ])
    }
}

/// The size ladder behind Dynamic and Fixed.
///
/// One screen for both, because they choose the same number -- how large the
/// cache may ever get -- and differ only in when it is paid for.
private final class CodeCacheSizeViewController: SettingsListViewController {

    private let mode: CodeCache.Mode

    init(mode: CodeCache.Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; these screens are built in code")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = mode == .dynamic ? "Dynamic" : "Fixed"
        navigationItem.largeTitleDisplayMode = .never
    }

    fileprivate override func buildSections() -> [SettingsSection] {
        let chosen = CodeCache.mode == mode ? CodeCache.chosenCeiling : nil
        let isCurrent = CodeCache.mode == mode

        // Auto first, and in both modes: it is a size like any other -- the one QEMU would have
        // picked -- and the only reason it used to sit a level up was that it had been mistaken for
        // a third way of paying for the cache.
        var rows = [
            SettingsRow(
                id: "auto",
                title: "Auto",
                detail: Mebibytes.describe(CodeCache.autoSize),
                accessory: isCurrent && chosen == nil ? .checkmark : .none,
                select: { [weak self] in self?.choose(nil) })
        ]

        rows += CodeCache.sizes.map { size in
            SettingsRow(
                id: "size-\(size)",
                title: Mebibytes.describe(size),
                accessory: isCurrent && chosen == size ? .checkmark : .none,
                select: { [weak self] in self?.choose(size) })
        }

        return [
            SettingsSection(
                header: mode == .dynamic ? "Grow Up To" : "Cache Size",
                footer: footerText,
                rows: rows)
        ]
    }

    /// Takes this screen's mode and the size just tapped, together.
    ///
    /// Both at once, because they are one decision: arriving here is already a
    /// choice of mode, and leaving without recording it would put someone on a
    /// Fixed screen while the cache stayed Dynamic.
    private func choose(_ size: Int?) {
        CodeCache.mode = mode
        CodeCache.chosenCeiling = size
        popToRoot()
    }

    /// The ladder, written out, so the steps are not a surprise.
    private static var ladderText: String {
        CodeCache.growthLadder.dropFirst().map(Mebibytes.describe).joined(separator: ", ")
    }

    private var footerText: String {
        switch mode {
        case .dynamic:
            let start: String = Mebibytes.describe(CodeCache.dynamicInitial)
            let steps: String = Self.ladderText

            // Built in pieces rather than one concatenation: the type checker gives up on a long
            // enough chain of interpolated strings, and says so as a compile error.
            let opening: String = "Starts at \(start), then doubles as it fills -- \(steps) -- "
            let stopping: String =
                "up to the limit chosen here."
            let tcti: String =
                " Without JIT the whole cache is there from the start."

            return opening + stopping + tcti

        case .fixed:
            let largest: String = Mebibytes.describe(CodeCache.sizes.last ?? 2048)
            return "Prepared in full before Linux starts, every time."
        }
    }
}
