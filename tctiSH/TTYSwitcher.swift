//
//  TTYSwitcher.swift
//  The screen for choosing, adding, arranging and closing TTYs.
//
//  Copyright © 2026 Ara Adkins.
//

import SwiftTerm
import UIKit

/// Shows every TTY at once, in the way Safari shows its tabs.
///
/// The locked system TTYs that Settings shows and any pinned TTYs are pills
/// along the top; the rest are cards, each with a regularly refreshed picture
/// of its screen. Tapping a TTY selects it and closes the switcher.
/// Long-pressing one opens its menu, and dragging a user TTY reorders it within
/// its section.
///
/// The main view controller adds the switcher as a child laid over the
/// terminal, so that the terminal stays in place underneath and keeps updating.
final class TTYSwitcherViewController: UIViewController {

    /// Asks the main view controller to close the switcher onto whichever TTY
    /// is selected by then. If `find` is not nil, the TTY's find bar opens too,
    /// searching for `find`, or empty if `find` is the empty string.
    var finish: (_ find: String?) -> Void = { _ in }

    private enum Section: Hashable {
        case pinned, cards, results
    }

    /// A TTY shown as a pill, a card, or a search result. The case is part of
    /// the item's identity, so pinning or unpinning a TTY makes it a different
    /// item, and the data source replaces its cell with one of the other kind.
    private enum Item: Hashable {
        case pill(UUID)
        case card(UUID)
        case result(UUID)

        /// The TTY's ID for a pill or a card, or nil for a search result.
        var shown: UUID? {
            switch self {
            case .pill(let id), .card(let id): id
            case .result: nil
            }
        }
    }

    /// The item that shows `tty` when no search is in effect: a pill for a
    /// system or pinned TTY, and a card for any other.
    private func item(for tty: TTY) -> Item {
        tty.isSystem || tty.isPinned ? .pill(tty.id) : .card(tty.id)
    }

    private let store = TTYs.shared

    private let background = UIVisualEffectView(effect: nil)
    private let content = UIView()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    private let searchCapsule = KeyBar.makeCapsule()
    private let searchField = UISearchTextField()
    private let cancelSearchButton = UIButton(configuration: .plain())
    private let addButton = UIButton(configuration: .plain())
    private let doneButton = UIButton(configuration: .plain())
    private let countLabel = UILabel()

    /// Fires while the switcher is open, to redraw the cards' pictures.
    private var thumbnailTimer: Timer?

    /// Builds the long-press menu for cards and pills. Its Search item selects
    /// the TTY and closes the switcher onto the TTY's find bar, with the find
    /// field empty.
    private lazy var ttyMenu = TTYMenu(presenter: self) { [weak self] tty in
        guard let self else { return }
        store.select(tty)
        finish("")
    }

    /// The notification observers, removed in `deinit`.
    private var observers: [any NSObjectProtocol] = []

    /// Whether `animateOut` has started. An opening animation that ends after
    /// this is set must not show the card's picture or start the thumbnail
    /// timer.
    private var closing = false

    /// The interval between redraws of the cards' pictures. A card is redrawn
    /// only if its TTY has had output since the last redraw.
    private static let thumbnailInterval: TimeInterval = 0.5

    private static let pillHeight: CGFloat = 44
    private static let margin: CGFloat = 16

    // MARK: Searching

    /// Whether the search field is expanded: from when it begins editing until
    /// Cancel or Escape ends the search.
    private var searching = false

    /// The search text, trimmed of whitespace, as of the last search run. When
    /// it is empty, the list shows the pills and cards instead of results.
    private var query = ""

    /// The matching TTYs in the order shown, each with its scrollback match.
    private var matches: [(id: UUID, match: ScrollbackMatch)] = []

    /// The next search run, delayed after each edit so that it runs once typing
    /// pauses.
    private var pendingSearch: DispatchWorkItem?

    /// Whether a card or pill is being dragged or dropped. Changes to the list
    /// are deferred until both are over, because a snapshot applied during a
    /// drag puts the dragged cell back where it started.
    private var dragging: Bool { collectionView.hasActiveDrag || collectionView.hasActiveDrop }
    private var refreshAfterDrag = false

    /// The constraints that size the search capsule, collapsed to a circle or
    /// expanded to hold the field. In a compact width it expands until Cancel
    /// reaches the trailing edge. In a regular width, where New and Done share
    /// the top, it expands to a set width. `searchExpanded` is whichever of the
    /// two expanded constraints applies.
    private var searchCollapsed: NSLayoutConstraint!
    private var searchExpanded: NSLayoutConstraint!
    private var compactExpanded: NSLayoutConstraint!
    private var regularExpanded: NSLayoutConstraint!

    /// The guide the bottom of the switcher's content rests on: the top of the
    /// keyboard while searching, and the bottom of the safe area otherwise. It
    /// does not follow the keyboard at other times because, as the switcher
    /// opens, the keyboard is still the terminal's, and is on its way down.
    private let floor = UILayoutGuide()
    private var floorOnKeyboard: NSLayoutConstraint!
    private var floorOnSafeArea: NSLayoutConstraint!

    /// The search field's leading offset in its capsule. It is set from where
    /// the field draws its magnifying glass, to center the glass in the
    /// collapsed circle.
    private var searchFieldLeading: NSLayoutConstraint!

    /// The constraints that put the buttons along the bottom in a compact
    /// width, as on iPhone, or along the top in a regular width, as on iPad.
    private var compactConstraints: [NSLayoutConstraint] = []
    private var regularConstraints: [NSLayoutConstraint] = []

    private var barsAlongTop: Bool { traitCollection.horizontalSizeClass == .regular }

    /// The expanded search capsule's width when the buttons are along the top.
    /// The constraint is not required, so the capsule narrows if it must.
    private static let regularSearchWidth: CGFloat = 400

    private static let buttonSize: CGFloat = 44

    // MARK: Setup

    override func viewDidLoad() {
        super.viewDidLoad()

        view.overrideUserInterfaceStyle = .dark
        view.tintColor = Accent.custom

        background.frame = view.bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(background)

        content.frame = view.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.alpha = 0
        background.contentView.addSubview(content)

        setUpCollectionView()
        setUpBars()
        observe()
        applyTint()
        applySnapshot(animated: false)
    }

    /// The color the switcher's background is tinted with, worked out from the
    /// selected terminal's background and the accent.
    ///
    /// Safari's tab switcher is glass over the start page's wallpaper, which
    /// differs in color from the pages on its cards. Here the glass is over the
    /// terminal, which is the same color as the cards, so the tint must supply
    /// a distinct color, and one that everything drawn on it can be read
    /// against.
    private var tint: UIColor {
        SwitcherBackground.color(
            cards: store.selected.view?.nativeBackgroundColor ?? .black, accent: Accent.color)
    }

    /// The effect the switcher is drawn on: on iOS 26, glass with the tint at
    /// 90% opacity, so that the terminal underneath shows only as movement;
    /// before iOS 26, a thick dark blur.
    private var backgroundEffect: UIVisualEffect {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.tintColor = tint.withAlphaComponent(0.9)
            return glass
        }
        return UIBlurEffect(style: .systemThickMaterialDark)
    }

    /// Applies the current tint. Before iOS 26, the tint is a translucent color
    /// on the content view, over the blur, so that it fades in with the
    /// content. On iOS 26 it is part of the glass, which is replaced only if it
    /// is already showing; otherwise `animateIn` sets it.
    private func applyTint() {
        if #unavailable(iOS 26.0) {
            content.backgroundColor = tint.withAlphaComponent(0.7)
        } else if background.effect != nil {
            background.effect = backgroundEffect
        }
    }

    private func setUpCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(collectionView)

        let card = UICollectionView.CellRegistration<TTYCardCell, UUID> {
            [weak self] cell, _, id in
            guard let self, let tty = store.tty(id) else { return }
            cell.show(tty, selected: tty === store.selected)
            cell.close = { [weak self, weak tty] in
                guard let tty else { return }
                self?.ttyMenu.confirmClose(tty)
            }
        }

        let pill = UICollectionView.CellRegistration<TTYPillCell, UUID> {
            [weak self] cell, _, id in
            guard let self, let tty = store.tty(id) else { return }
            cell.surface = tint
            cell.show(tty, selected: tty === store.selected)
        }

        let result = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> {
            [weak self] cell, _, id in
            guard let self, let tty = store.tty(id) else { return }
            configure(result: cell, for: tty)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            [weak self] collectionView, indexPath, item in
            switch item {
            case .result(let id):
                return collectionView.dequeueConfiguredReusableCell(
                    using: result, for: indexPath, item: id)
            case .pill(let id):
                return collectionView.dequeueConfiguredReusableCell(
                    using: pill, for: indexPath, item: id)
            case .card(let id):
                return collectionView.dequeueConfiguredReusableCell(
                    using: card, for: indexPath, item: id)
            }
        }
    }

    private func setUpBars() {
        // Styles each button as a circle of glass, like the buttons in Safari's tab switcher, with
        // Done prominent in the accent color. Before iOS 26, gray and filled buttons stand in.
        func style(_ button: UIButton, _ symbol: String, _ label: String, prominent: Bool = false) {
            var configuration: UIButton.Configuration
            if #available(iOS 26.0, *) {
                configuration = prominent ? .prominentGlass() : .glass()
            } else {
                configuration = prominent ? .filled() : .gray()
            }
            configuration.image = UIImage(systemName: symbol)
            configuration.preferredSymbolConfigurationForImage =
                UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            configuration.baseForegroundColor = prominent ? Accent.foreground : .label
            configuration.cornerStyle = .capsule
            button.configuration = configuration
            button.accessibilityLabel = label
            button.translatesAutoresizingMaskIntoConstraints = false

            // Uses the system pointer effect, which for a glass button matches Safari's.
            button.isPointerInteractionEnabled = true
        }

        // Search is a search field in a capsule of glass. Until it is tapped, the capsule is a
        // circle showing only the field's magnifying glass; then it stretches out to hold the text,
        // as Safari's search does.
        if #unavailable(iOS 26.0) {
            searchCapsule.layer.cornerRadius = Self.buttonSize / 2
        }
        searchCapsule.translatesAutoresizingMaskIntoConstraints = false
        searchCapsule.hoverStyle = UIHoverStyle(shape: .capsule)
        searchCapsule.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(search)))
        searchCapsule.contentView.addSubview(searchField)

        searchField.accessibilityLabel = "Search TTYs"
        searchField.font = .preferredFont(forTextStyle: .body)
        searchField.adjustsFontForContentSizeCategory = true
        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.spellCheckingType = .no
        searchField.returnKeyType = .search
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.addAction(
            UIAction { [weak self] _ in self?.beginSearch() }, for: .editingDidBegin)
        searchField.addAction(
            UIAction { [weak self] _ in self?.searchChanged() }, for: .editingChanged)

        style(cancelSearchButton, "xmark", "Cancel Search")
        cancelSearchButton.isHidden = true
        cancelSearchButton.alpha = 0
        cancelSearchButton.addAction(
            UIAction { [weak self] _ in self?.endSearch() }, for: .touchUpInside)

        style(addButton, "plus", "New TTY")
        addButton.addAction(UIAction { [weak self] _ in self?.add() }, for: .touchUpInside)

        style(doneButton, "checkmark", "Done", prominent: true)
        doneButton.addAction(UIAction { [weak self] _ in self?.finish(nil) }, for: .touchUpInside)

        countLabel.font = .preferredFont(forTextStyle: .body)
        countLabel.textColor = .secondaryLabel
        countLabel.textAlignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        [
            searchCapsule, cancelSearchButton, addButton, doneButton, countLabel,
        ]
        .forEach(content.addSubview)

        let safe = content.safeAreaLayoutGuide
        let inset = Self.margin - 6
        let button = Self.buttonSize
        let keyboard = view.keyboardLayoutGuide

        searchFieldLeading = searchField.leadingAnchor.constraint(
            equalTo: searchCapsule.contentView.leadingAnchor)

        NSLayoutConstraint.activate([
            searchCapsule.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            searchCapsule.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: inset),
            searchCapsule.heightAnchor.constraint(equalToConstant: button),

            searchFieldLeading,
            searchField.trailingAnchor.constraint(
                equalTo: searchCapsule.contentView.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchCapsule.contentView.centerYAnchor),

            // Cancel sits just past the capsule's trailing edge, so it moves as the capsule
            // stretches.
            cancelSearchButton.centerYAnchor.constraint(equalTo: searchCapsule.centerYAnchor),
            cancelSearchButton.leadingAnchor.constraint(
                equalTo: searchCapsule.trailingAnchor, constant: 8),
            cancelSearchButton.widthAnchor.constraint(equalToConstant: button),
            cancelSearchButton.heightAnchor.constraint(equalToConstant: button),

            collectionView.topAnchor.constraint(equalTo: searchCapsule.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            addButton.widthAnchor.constraint(equalToConstant: button),
            addButton.heightAnchor.constraint(equalToConstant: button),
            doneButton.widthAnchor.constraint(equalToConstant: button),
            doneButton.heightAnchor.constraint(equalToConstant: button),
            doneButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -inset),
        ])

        content.addLayoutGuide(floor)
        floorOnKeyboard = floor.bottomAnchor.constraint(equalTo: keyboard.topAnchor)
        floorOnSafeArea = floor.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        NSLayoutConstraint.activate([
            floor.heightAnchor.constraint(equalToConstant: 0),
            floor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            floor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            searching ? floorOnKeyboard : floorOnSafeArea,
        ])

        // In a compact width, the buttons sit along the bottom, on the floor: New on the left, Done
        // on the right, and the count centered between them.
        compactConstraints = [
            collectionView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),
            addButton.bottomAnchor.constraint(equalTo: floor.topAnchor, constant: -8),
            addButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: inset),
            doneButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            countLabel.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            countLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        ]

        // In a regular width, the buttons sit along the top beside Search, as in Safari on iPad:
        // New, then Done in the corner, with the count centered. Cancel keeps clear of New.
        regularConstraints = [
            collectionView.bottomAnchor.constraint(equalTo: floor.topAnchor),
            addButton.centerYAnchor.constraint(equalTo: searchCapsule.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -12),
            doneButton.centerYAnchor.constraint(equalTo: searchCapsule.centerYAnchor),
            countLabel.centerYAnchor.constraint(equalTo: searchCapsule.centerYAnchor),
            countLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            cancelSearchButton.trailingAnchor.constraint(
                lessThanOrEqualTo: addButton.leadingAnchor, constant: -16),
        ]

        searchCollapsed = searchCapsule.widthAnchor.constraint(equalToConstant: button)
        compactExpanded = cancelSearchButton.trailingAnchor.constraint(
            equalTo: safe.trailingAnchor, constant: -inset)
        regularExpanded = searchCapsule.widthAnchor.constraint(
            equalToConstant: Self.regularSearchWidth)
        regularExpanded.priority = .defaultHigh

        layOutBars()
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) {
            (self: Self, _: UITraitCollection) in
            self.layOutBars()
        }

        refreshBars()
    }

    /// Puts the buttons along the top or the bottom to suit the horizontal size
    /// class, and sizes the search capsule for whether a search is active.
    private func layOutBars() {
        let top = barsAlongTop

        // Deactivates before activating, so that the two sets are never active together and
        // conflicting.
        NSLayoutConstraint.deactivate(
            (top ? compactConstraints : regularConstraints)
                + [searchCollapsed, compactExpanded, regularExpanded])
        NSLayoutConstraint.activate(top ? regularConstraints : compactConstraints)

        searchExpanded = top ? regularExpanded : compactExpanded
        (searching ? searchExpanded : searchCollapsed).isActive = true
        countLabel.alpha = searching && top ? 0 : 1
    }

    private func observe() {
        let center = NotificationCenter.default

        observers.append(contentsOf: [
            center.addObserver(forName: TTYs.didChange, object: nil, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                if !query.isEmpty {
                    runSearch()
                }
                refreshBars()
                guard !dragging else {
                    refreshAfterDrag = true
                    return
                }
                applySnapshot(animated: true)
                reconfigureAll()
            },

            center.addObserver(forName: TTYs.statusDidChange, object: nil, queue: .main) {
                [weak self] note in
                guard let tty = note.object as? TTY else { return }
                self?.reconfigure([tty])
            },

            center.addObserver(forName: TTYs.selectionDidChange, object: nil, queue: .main) {
                [weak self] note in
                guard let self else { return }
                reconfigure([note.object as? TTY, store.selected].compactMap { $0 })
            },

            center.addObserver(forName: Accent.didChange, object: nil, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                view.tintColor = Accent.custom
                doneButton.configuration?.baseForegroundColor = Accent.foreground
                applyTint()
                reconfigureAll()
            },
        ])
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        thumbnailTimer?.invalidate()
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // The field positions its magnifying glass itself, so the whole field is offset to put the
        // glass at the center of the collapsed circle, rounded to whole pixels.
        let glass = searchField.leftViewRect(forBounds: searchField.bounds)
        let scale = traitCollection.displayScale
        let leading = ((Self.buttonSize / 2 - glass.midX) * scale).rounded() / scale
        if searchField.bounds.height > 0, searchFieldLeading.constant != leading {
            searchFieldLeading.constant = leading
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.interSectionSpacing = 20

        return UICollectionViewCompositionalLayout(
            sectionProvider: { [weak self] index, environment in
                guard let self, let section = dataSource?.sectionIdentifier(for: index) else {
                    return nil
                }
                switch section {
                case .pinned: return pillSection(environment)
                case .cards: return cardSection(environment)
                case .results: return resultSection(environment)
                }
            }, configuration: configuration)
    }

    /// The width available to a section's items: the container's width less the
    /// safe area's side insets and the section's side margins.
    private func usableWidth(_ environment: NSCollectionLayoutEnvironment) -> CGFloat {
        let insets = view.safeAreaInsets
        return environment.container.effectiveContentSize.width - insets.left - insets.right
            - Self.margin * 2
    }

    /// A section of rows of `columns` equal items, each `height` tall.
    ///
    /// `outset` is how far an item draws beyond its visible body at the sides
    /// and top, as a card does for its selection ring. The section is widened
    /// by `outset` at each side and raised by it, and the spacing is reduced to
    /// match, so the bodies line up and are spaced as if there were no outset.
    private func grid(
        columns: Int, height: CGFloat, spacing: CGFloat, rowSpacing: CGFloat,
        outset: CGFloat = 0
    ) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
            repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(spacing - outset * 2)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = rowSpacing - outset
        section.contentInsetsReference = .safeArea
        section.contentInsets = NSDirectionalEdgeInsets(
            top: -outset, leading: Self.margin - outset, bottom: 0,
            trailing: Self.margin - outset)
        return section
    }

    /// One pill to a row for each whole 200 points of width, but at least two,
    /// as on a phone.
    private func pillSection(_ environment: NSCollectionLayoutEnvironment)
        -> NSCollectionLayoutSection
    {
        let columns = max(2, Int(usableWidth(environment) / 200))
        return grid(columns: columns, height: Self.pillHeight, spacing: 8, rowSpacing: 8)
    }

    /// Two cards to a row below 500 points of width, as on a phone in portrait,
    /// and three otherwise. Each card's picture has the terminal's aspect
    /// ratio.
    private func cardSection(_ environment: NSCollectionLayoutEnvironment)
        -> NSCollectionLayoutSection
    {
        let width = usableWidth(environment)
        let columns = width < 500 ? 2 : 3
        let spacing: CGFloat = 16
        let cardWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)

        let frame = store.terminalFrame
        let aspect = frame.width > 0 ? frame.height / frame.width : 1
        let outset = TTYCardCell.ringOutset
        let height = (cardWidth * aspect).rounded() + outset + TTYCardCell.labelHeight

        return grid(
            columns: columns, height: height, spacing: spacing, rowSpacing: 20, outset: outset)
    }

    private func resultSection(_ environment: NSCollectionLayoutEnvironment)
        -> NSCollectionLayoutSection
    {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
    }

    // MARK: Contents

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

        if query.isEmpty {
            snapshot.appendSections([.pinned, .cards])
            snapshot.appendItems(
                (store.shownSystem + store.pinned).map { .pill($0.id) }, toSection: .pinned)
            snapshot.appendItems(store.cards.map { .card($0.id) }, toSection: .cards)
        } else {
            snapshot.appendSections([.results])
            snapshot.appendItems(matches.map { .result($0.id) }, toSection: .results)
        }

        dataSource.apply(snapshot, animatingDifferences: animated && view.window != nil)
    }

    /// Redraws the cells showing these TTYs, whichever kind of item each is.
    /// During a drag, it instead marks the list to be refreshed afterward.
    private func reconfigure(_ ttys: [TTY]) {
        guard !dragging else {
            refreshAfterDrag = true
            return
        }
        var snapshot = dataSource.snapshot()
        let items = ttys.flatMap { [Item.pill($0.id), .card($0.id), .result($0.id)] }
            .filter { snapshot.indexOfItem($0) != nil }
        guard !items.isEmpty else { return }

        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigureAll() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func refreshBars() {
        let count = store.users.count
        countLabel.text = count == 1 ? "1 TTY" : "\(count) TTYs"
        addButton.isEnabled = store.canAdd
        addButton.accessibilityHint =
            store.canAdd ? nil : "There can be at most \(TTY.userLimit) TTYs."
    }

    private func configure(result cell: UICollectionViewListCell, for tty: TTY) {
        let match = matches.first { $0.id == tty.id }?.match

        var content = UIListContentConfiguration.subtitleCell()
        content.text = tty.name
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.secondaryAttributedText = match?.snippet
        content.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.backgroundConfiguration = .clear()

        var accessories: [UICellAccessory] = []
        if let count = match?.count, count > 0 {
            accessories.append(
                .label(
                    text: count == 1 ? "1 match" : "\(count) matches",
                    options: .init(tintColor: .secondaryLabel)))
        }
        if !tty.statuses.isEmpty {
            let status = TTYStatusView()
            status.pointSize = 15
            status.show(tty.statuses)
            accessories.append(
                .customView(configuration: .init(customView: status, placement: .trailing())))
        }
        cell.accessories = accessories
    }

    // MARK: Appearing and disappearing

    /// Fades the switcher in over `terminal`, while a snapshot of `terminal`
    /// shrinks into the selected TTY's card. If that TTY has no card on screen,
    /// the switcher only fades in. Once done, starts the thumbnail timer,
    /// unless the switcher has begun closing in the meantime.
    func animateIn(from terminal: UIView) {
        view.layoutIfNeeded()
        revealSelected()
        collectionView.layoutIfNeeded()

        let start = view.convert(terminal.frame, from: terminal.superview)
        let card = selectedCard()

        guard let card, let snapshot = terminal.snapshotView(afterScreenUpdates: false) else {
            UIView.animate(withDuration: 0.3) {
                self.background.effect = self.backgroundEffect
                self.content.alpha = 1
            } completion: { _ in
                guard !self.closing else { return }
                self.startThumbnails()
            }
            return
        }

        let end = view.convert(card.thumbnail.frame, from: card.thumbnail.superview)
        snapshot.frame = start
        snapshot.clipsToBounds = true
        snapshot.layer.cornerCurve = .continuous
        view.addSubview(snapshot)
        card.thumbnail.alpha = 0

        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
            options: []
        ) {
            self.background.effect = self.backgroundEffect
            self.content.alpha = 1
            snapshot.frame = end
            snapshot.layer.cornerRadius = TTYCardCell.cornerRadius
        } completion: { _ in
            snapshot.removeFromSuperview()
            guard !self.closing else { return }
            card.thumbnail.alpha = 1
            self.startThumbnails()
        }
    }

    /// Fades the switcher out while a snapshot of `terminal` grows from the
    /// selected TTY's card to fill `terminal`'s frame, then calls `completion`.
    /// While searching, or if that TTY has no card on screen, the switcher only
    /// fades out. The caller must already have put the selected TTY's terminal
    /// in place underneath.
    func animateOut(to terminal: UIView, completion: @escaping () -> Void) {
        closing = true
        stopThumbnails()
        view.endEditing(true)

        let end = view.convert(terminal.frame, from: terminal.superview)
        let card = query.isEmpty ? selectedCard() : nil
        let snapshot = card.flatMap { _ in terminal.snapshotView(afterScreenUpdates: true) }

        if let card, let snapshot {
            snapshot.frame = view.convert(card.thumbnail.frame, from: card.thumbnail.superview)
            snapshot.clipsToBounds = true
            snapshot.layer.cornerCurve = .continuous
            snapshot.layer.cornerRadius = TTYCardCell.cornerRadius
            view.addSubview(snapshot)
            card.thumbnail.alpha = 0
        }

        UIView.animate(
            withDuration: snapshot == nil ? 0.25 : 0.4, delay: 0, usingSpringWithDamping: 0.92,
            initialSpringVelocity: 0, options: []
        ) {
            self.background.effect = nil
            self.content.alpha = 0
            snapshot?.frame = end
            snapshot?.layer.cornerRadius = 0
        } completion: { _ in
            snapshot?.removeFromSuperview()
            completion()
        }
    }

    /// The selected TTY's card cell, or nil if that TTY is shown as a pill or
    /// its card is not on screen.
    private func selectedCard() -> TTYCardCell? {
        guard let indexPath = dataSource.indexPath(for: item(for: store.selected)) else {
            return nil
        }
        return collectionView.cellForItem(at: indexPath) as? TTYCardCell
    }

    /// Scrolls the selected TTY into view.
    private func revealSelected() {
        guard let indexPath = dataSource.indexPath(for: item(for: store.selected)) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    }

    // MARK: Pictures

    private func startThumbnails() {
        stopThumbnails()
        let timer = Timer(timeInterval: Self.thumbnailInterval, repeats: true) { [weak self] _ in
            self?.refreshThumbnails()
        }
        RunLoop.main.add(timer, forMode: .common)
        thumbnailTimer = timer
    }

    private func stopThumbnails() {
        thumbnailTimer?.invalidate()
        thumbnailTimer = nil
    }

    /// Redraws the picture on each visible card whose TTY has had output since
    /// the picture was last drawn.
    private func refreshThumbnails() {
        for case let card as TTYCardCell in collectionView.visibleCells {
            card.refreshThumbnail(force: false)
        }
    }

    // MARK: Actions

    func add() {
        guard let tty = store.add() else { return }
        store.select(tty)
        finish(nil)
    }

    private func choose(_ tty: TTY) {
        store.select(tty)
        finish(nil)
    }

    // MARK: Searching

    /// Starts search mode when the field begins editing: sets the placeholder,
    /// shows Cancel, and stretches the capsule out.
    private func beginSearch() {
        guard !searching else { return }
        searching = true

        searchField.placeholder = "Search TTYs"
        cancelSearchButton.isHidden = false
        cancelSearchButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        stretchSearch(open: true)
    }

    private func endSearch() {
        pendingSearch?.cancel()
        searching = false
        searchField.text = nil
        searchField.resignFirstResponder()
        runSearch()
        _ = becomeFirstResponder()

        // Clears the placeholder, which would otherwise show cut off in the collapsed circle.
        searchField.placeholder = nil
        stretchSearch(open: false) { [weak self] in
            guard let self, !searching else { return }
            cancelSearchButton.isHidden = true
        }
    }

    /// Stretches the search capsule out to hold the field's text, or shrinks it
    /// back into a circle, with Cancel growing in beside it or shrinking away.
    /// While open, the floor rests on the keyboard instead of the safe area.
    private func stretchSearch(open: Bool, completion: (() -> Void)? = nil) {
        content.layoutIfNeeded()

        // Deactivates before activating, so that each pair is never active together and
        // conflicting.
        (open ? searchCollapsed : searchExpanded).isActive = false
        (open ? searchExpanded : searchCollapsed).isActive = true
        (open ? floorOnSafeArea : floorOnKeyboard).isActive = false
        (open ? floorOnKeyboard : floorOnSafeArea).isActive = true
        let hidesCount = open && barsAlongTop

        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.content.layoutIfNeeded()
            self.countLabel.alpha = hidesCount ? 0 : 1
            self.cancelSearchButton.alpha = open ? 1 : 0
            self.cancelSearchButton.transform =
                open ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
        } completion: { _ in
            completion?()
        }
    }

    private func searchChanged() {
        pendingSearch?.cancel()
        let search = DispatchWorkItem { [weak self] in self?.runSearch() }
        pendingSearch = search
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: search)
    }

    /// Finds the user TTYs whose name, default name, console or scrollback
    /// contains the query, ignoring case, and shows them as results. An empty
    /// query shows the pills and cards again.
    private func runSearch() {
        pendingSearch = nil
        query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        matches = []
        if !query.isEmpty {
            for tty in store.users {
                let match = tty.view.map { ScrollbackMatch.find(query, in: $0) } ?? .none
                let named =
                    tty.name.localizedCaseInsensitiveContains(query)
                    || tty.defaultName.localizedCaseInsensitiveContains(query)
                    || tty.device?.localizedCaseInsensitiveContains(query) == true
                if named || match.count > 0 {
                    matches.append((tty.id, match))
                }
            }
        }
        applySnapshot(animated: true)

        // A TTY that matched before and still matches keeps the same item, which applying the
        // snapshot does not redraw, so every cell is reconfigured to show the new count and
        // snippet.
        if !dragging {
            reconfigureAll()
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    /// The key commands that apply only inside the switcher: Escape and
    /// Command-F. The commands that show and hide the switcher, and New TTY,
    /// belong to the main view controller, because they are also in the menu
    /// bar.
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                title: "Done", action: #selector(escape), input: UIKeyCommand.inputEscape),
            UIKeyCommand(
                title: "Search TTYs", action: #selector(search), input: "f",
                modifierFlags: .command),
        ]
    }

    @objc private func escape() {
        if searching {
            endSearch()
        } else {
            finish(nil)
        }
    }

    /// Starts a search by making the field first responder. The field's
    /// editingDidBegin action then stretches it out.
    @objc private func search() { _ = searchField.becomeFirstResponder() }
}

// MARK: - Choosing, and the long-press menu

extension TTYSwitcherViewController: UICollectionViewDelegate {

    private func tty(at indexPath: IndexPath) -> TTY? {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .pill(let id), .card(let id), .result(let id): store.tty(id)
        case nil: nil
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let tty = tty(at: indexPath) else { return }

        if case .result = dataSource.itemIdentifier(for: indexPath),
            matches.first(where: { $0.id == tty.id })?.match.count ?? 0 > 0
        {
            store.select(tty)
            finish(query)
            return
        }
        choose(tty)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
            dataSource.itemIdentifier(for: indexPath)?.shown != nil,
            let tty = tty(at: indexPath)
        else { return nil }

        return UIContextMenuConfiguration(identifier: tty.id as NSUUID, previewProvider: nil) {
            [weak self] _ in
            guard let self else { return nil }
            return ttyMenu.menu(for: tty, in: collectionView.contextMenuInteraction)
        }
    }
}

// MARK: - Dragging to reorder

extension TTYSwitcherViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {

    func collectionView(
        _ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard query.isEmpty, let id = dataSource.itemIdentifier(for: indexPath)?.shown,
            store.tty(id)?.isSystem == false
        else { return [] }

        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = id
        return [item]
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dragSessionIsRestrictedToDraggingApplication session: UIDragSession
    ) -> Bool {
        true
    }

    // MARK: Lifting

    /// The outline a lifted card or pill is clipped to, for drags and context
    /// menus, in place of its cell's full rectangle. Nil for a search result.
    private func previewPath(at indexPath: IndexPath) -> UIBezierPath? {
        switch collectionView.cellForItem(at: indexPath) {
        case let card as TTYCardCell: card.previewPath
        case let pill as TTYPillCell: pill.previewPath
        default: nil
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        guard let path = previewPath(at: indexPath) else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = path
        parameters.backgroundColor = .clear
        return parameters
    }

    func collectionView(
        _ collectionView: UICollectionView, dropPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        self.collectionView(collectionView, dragPreviewParametersForItemAt: indexPath)
    }

    private func menuPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let id = configuration.identifier as? UUID, let tty = store.tty(id),
            let indexPath = dataSource.indexPath(for: item(for: tty)),
            let cell = collectionView.cellForItem(at: indexPath),
            let path = previewPath(at: indexPath)
        else { return nil }

        let parameters = UIPreviewParameters()
        parameters.visiblePath = path
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: cell, parameters: parameters)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        menuPreview(for: configuration)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        menuPreview(for: configuration)
    }

    /// Allows a drop only within the dragged TTY's section and, in the pinned
    /// section, only after the system TTYs, which always come first.
    func collectionView(
        _ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destination: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard let id = session.localDragSession?.items.first?.localObject as? UUID,
            let source = dataSource.indexPath(for: .pill(id))
                ?? dataSource.indexPath(for: .card(id)),
            let destination,
            destination.section == source.section,
            destination.item >= firstMovable(inSection: source.section)
        else { return UICollectionViewDropProposal(operation: .forbidden) }

        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        guard let item = coordinator.items.first, let source = item.sourceIndexPath,
            let destination = coordinator.destinationIndexPath,
            let section = dataSource.sectionIdentifier(for: source.section)
        else { return }

        // Moves the item in the list first, without animation, because the drop animates the cell
        // into place. Then reorders the store; its change notification arrives while the drop is
        // still active, so the refresh it causes is deferred until the drop ends.
        var snapshot = dataSource.snapshot()
        let items = snapshot.itemIdentifiers(inSection: section)
        let target = min(max(destination.item, 0), items.count - 1)
        if items.indices.contains(source.item), target != source.item {
            let moved = items[source.item]
            if target > source.item {
                snapshot.moveItem(moved, afterItem: items[target])
            } else {
                snapshot.moveItem(moved, beforeItem: items[target])
            }
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        let ids = snapshot.itemIdentifiers(inSection: section).compactMap(\.shown)
        store.reorder(ids.filter { store.tty($0)?.isSystem == false })
        coordinator.drop(item.dragItem, toItemAt: destination)
    }

    func collectionView(
        _ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession
    ) {
        refreshIfDragged()
    }

    func collectionView(
        _ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession
    ) {
        refreshIfDragged()
    }

    /// Applies the changes deferred during a drag, once both the drag and the
    /// drop are over, checking again every 0.1 seconds until they are.
    private func refreshIfDragged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, refreshAfterDrag else { return }
            guard !dragging else {
                refreshIfDragged()
                return
            }
            refreshAfterDrag = false
            applySnapshot(animated: false)
            reconfigureAll()
        }
    }

    private func firstMovable(inSection index: Int) -> Int {
        dataSource.sectionIdentifier(for: index) == .pinned ? store.shownSystem.count : 0
    }
}

// MARK: - Finding text in scrollback

/// How many times a term occurs in a terminal's buffer, scrollback included,
/// and a snippet of the last line that contains it, with the term highlighted.
struct ScrollbackMatch {

    var count: Int
    var snippet: NSAttributedString?

    static let none = ScrollbackMatch(count: 0, snippet: nil)

    /// The most characters before the match that the snippet keeps, so that the
    /// match stays visible when the one-line label truncates the snippet.
    private static let lead = 24

    /// Counts the matches with SwiftTerm's `searchMatchSummary`, which the find
    /// bar also uses, so the two counts agree. It searches the buffer being
    /// displayed, ignoring case, matches across wrapped lines, wide characters
    /// and tabs, and stops counting at 1,000. The snippet comes from the last
    /// row of that buffer that holds the whole term; if every match is split
    /// across a line wrap, there is no snippet.
    static func find(_ term: String, in view: TerminalView) -> ScrollbackMatch {
        let count = view.searchMatchSummary(term).total
        guard count > 0 else { return .none }

        // Cells skipped by a tab, and the second half of a wide character, read as NUL, so they are
        // replaced with spaces.
        let text = String(
            decoding: view.getTerminal().getBufferAsData(kind: .active), as: UTF8.self
        )
        .replacingOccurrences(of: "\u{0}", with: " ")
        let last = text.split(separator: "\n", omittingEmptySubsequences: true).reversed()
            .lazy.compactMap { line in
                line.range(of: term, options: [.caseInsensitive, .backwards]).map { (line, $0) }
            }.first

        return ScrollbackMatch(count: count, snippet: last.map { snippet($0.0, $0.1) })
    }

    private static func snippet(_ line: Substring, _ hit: Range<Substring.Index>)
        -> NSAttributedString
    {
        let start =
            line.index(hit.lowerBound, offsetBy: -lead, limitedBy: line.startIndex)
            ?? line.startIndex
        let ellipsis = start > line.startIndex ? "…" : ""
        let leading = ellipsis + String(line[start..<hit.lowerBound].drop(while: \.isWhitespace))

        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let snippet = NSMutableAttributedString(
            string: leading, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        snippet.append(
            NSAttributedString(
                string: String(line[hit]),
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: Accent.color,
                ]))
        var after = line[hit.upperBound...]
        while after.last?.isWhitespace == true {
            after.removeLast()
        }
        snippet.append(
            NSAttributedString(
                string: String(after),
                attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
        return snippet
    }
}

// MARK: - The background's color

/// Works out the switcher's background color: the accent's hue, muted, at a
/// lightness chosen so that everything drawn on it reads well.
///
/// The color is built in OKLab, where lightness and hue are independent, so the
/// lightness can be changed without shifting the hue. The lightness is chosen
/// by contrast ratio, as WCAG measures it, against three things:
///
/// - The cards, whose color is the terminal's background: the background is
///   far enough from them that they stand out as panels.
/// - White text, which the switcher's labels use: it stays comfortably
///   readable.
/// - The accent, which rings the selected card: it stays clearly visible.
///
/// The switcher's interface is always dark, so the background is always dark. A
/// light terminal's cards stand out against it by being light.
enum SwitcherBackground {

    /// The contrast ratio the background aims for against dark cards.
    static let cardContrast = 1.6

    /// The least contrast ratio white text may have against the background.
    static let textContrast = 7.0

    /// The least contrast ratio the accent may have against the background.
    static let accentContrast = 3.0

    /// The background's OKLab chroma: enough to read as the accent's hue, and
    /// little enough to stay a background. A less colorful accent lowers it.
    static let chroma = 0.04

    /// The contrast ratio between a card or pill and its appearance under the
    /// pointer.
    static let hoverContrast = 1.19

    static func color(cards: UIColor, accent: UIColor) -> UIColor {
        let cardLuminance = luminance(linear(cards))
        let accentLuminance = luminance(linear(accent))

        // Aims for `cardContrast` above dark cards, but never so light that white text or the
        // accent fall below their minimum contrast. Light cards already stand out against any
        // background dark enough for the text, so for them the target is a low fixed luminance.
        var target = cardLuminance < 0.18 ? cardContrast * (cardLuminance + 0.05) - 0.05 : 0.05
        target = min(target, 1.05 / textContrast - 0.05)
        target = min(target, (accentLuminance + 0.05) / accentContrast - 0.05)
        target = max(target, 0)

        let accentLab = oklab(linear(accent))
        let accentChroma = (accentLab.a * accentLab.a + accentLab.b * accentLab.b).squareRoot()
        let hue = atan2(accentLab.b, accentLab.a)
        let c = min(chroma, accentChroma)

        // Finds the lightness that gives the target luminance by bisection, which works because
        // luminance rises with lightness.
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if luminance(clamped(fromOklab(mid, c * cos(hue), c * sin(hue)))) < target {
                low = mid
            } else {
                high = mid
            }
        }

        let rgb = clamped(fromOklab(low, c * cos(hue), c * sin(hue)))
        return UIColor(
            red: CGFloat(encode(rgb.r)), green: CGFloat(encode(rgb.g)),
            blue: CGFloat(encode(rgb.b)), alpha: 1)
    }

    /// The color and alpha to lay over `base` under the pointer, so that it
    /// changes by the contrast ratio `hoverContrast`. The color is white, which
    /// lightens `base` as Safari's tabs do, unless even opaque white could not
    /// reach that contrast against `base`; then it is black.
    static func hoverOverlay(over base: UIColor) -> (color: UIColor, alpha: CGFloat) {
        let baseLuminance = luminance(linear(base)) + 0.05
        let lighten = 1.05 / baseLuminance >= hoverContrast
        let top: UIColor = lighten ? .white : .black

        // Finds the alpha by bisection, which works because the contrast grows with the alpha.
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let luminance = luminance(linear(blend(top, alpha: mid, over: base))) + 0.05
            let ratio = lighten ? luminance / baseLuminance : baseLuminance / luminance
            if ratio < hoverContrast {
                low = mid
            } else {
                high = mid
            }
        }
        return (top, CGFloat(high))
    }

    /// The opaque color of `top` laid over `base` at `alpha`, composited as
    /// UIKit does: on the encoded sRGB components, not in linear light.
    static func blend(_ top: UIColor, alpha: Double, over base: UIColor) -> UIColor {
        var (tr, tg, tb, ta): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let a = CGFloat(alpha)
        return UIColor(
            red: br + (tr - br) * a, green: bg + (tg - bg) * a, blue: bb + (tb - bb) * a,
            alpha: 1)
    }

    private typealias RGB = (r: Double, g: Double, b: Double)

    /// A color's linear sRGB components.
    private static func linear(_ color: UIColor) -> RGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (decode(Double(r)), decode(Double(g)), decode(Double(b)))
    }

    private static func decode(_ v: Double) -> Double {
        let magnitude = abs(v)
        let linear =
            magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
        return v < 0 ? -linear : linear
    }

    private static func encode(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func clamped(_ rgb: RGB) -> RGB {
        (min(max(rgb.r, 0), 1), min(max(rgb.g, 0), 1), min(max(rgb.b, 0), 1))
    }

    /// Relative luminance, as WCAG defines it.
    private static func luminance(_ rgb: RGB) -> Double {
        0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
    }

    private static func oklab(_ rgb: RGB) -> (l: Double, a: Double, b: Double) {
        let l = cbrt(0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b)
        let m = cbrt(0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b)
        let s = cbrt(0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    private static func fromOklab(_ lightness: Double, _ a: Double, _ b: Double) -> RGB {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }
}
