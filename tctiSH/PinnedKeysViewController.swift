//
//  PinnedKeysViewController.swift
//  Choosing which keys sit on the key bar, and in what order.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

/// The pinned keys, as a list that reorders, with everything else below it to
/// add from.
final class PinnedKeysViewController: UIViewController, UICollectionViewDelegate {

    /// The pinned keys, then the rest under the same groups as More's.
    private enum Section: Hashable {
        case pinned
        case group(BarKey.Group)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, BarKey>!

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Pinned Keys"
        navigationItem.largeTitleDisplayMode = .never

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        // Editing throughout, so the handles and the add and remove buttons are always there, as
        // they are on the system's screens for arranging things.
        collectionView.isEditing = true
        collectionView.allowsSelectionDuringEditing = true

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        makeDataSource()
        apply(animated: false)
    }

    /// How many fit on the bar at the app's current width.
    ///
    /// The app's window rather than this screen's, which on iPad is a sheet
    /// narrower than the keyboard the bar sits on.
    private var capacity: Int {
        guard let window = view.window else { return KeyBar.capacity(forWidth: view.bounds.width) }

        // Less the window's safe area at the sides, as the bar keeps clear of it too.
        let insets = window.safeAreaInsets
        return KeyBar.capacity(forWidth: window.bounds.width - insets.left - insets.right)
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            configuration.footerMode = index == 0 ? .supplementary : .none
            return NSCollectionLayoutSection.list(
                using: configuration, layoutEnvironment: environment)
        }
    }

    private func makeDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, BarKey> {
            [weak self] cell, indexPath, key in
            guard let self else { return }

            var content = UIListContentConfiguration.valueCell()
            content.text = key.name
            content.secondaryText = key.group == .characters ? key.glyph : nil
            content.image = key.icon
            content.imageProperties.tintColor = .tintColor

            let pinned = indexPath.section == 0
            if pinned {
                // Past what fits, it's still pinned, but it won't be on the bar at this width.
                if indexPath.item >= capacity {
                    content.textProperties.color = .secondaryLabel
                    content.imageProperties.tintColor = .secondaryLabel
                }

                cell.accessories = [
                    .delete(displayed: .always, actionHandler: { [weak self] in self?.unpin(key) }),
                    .reorder(displayed: .always),
                ]
            } else {
                cell.accessories = [
                    .insert(displayed: .always, actionHandler: { [weak self] in self?.pin(key) })
                ]
            }

            cell.contentConfiguration = content
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .group(let group): content.text = group.title
            default: content.text = "On the Bar"
            }
            view.contentConfiguration = content
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }

            var content = UIListContentConfiguration.footer()
            content.text =
                "Pinned keys sit on the bar in this order. \(Self.fit(capacity)) at this width, beside Hide Keyboard; any past that are grayed out, and stay in More with every key not on the bar."
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource<Section, BarKey>(
            collectionView: collectionView
        ) { collectionView, indexPath, key in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: key)
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            let registration = kind == UICollectionView.elementKindSectionHeader ? header : footer
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: registration, for: indexPath)
        }

        dataSource.reorderingHandlers.canReorderItem = { [weak self] key in
            self?.dataSource.snapshot().sectionIdentifier(containingItem: key) == .pinned
        }

        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            BarKey.pinned = transaction.finalSnapshot.itemIdentifiers(inSection: .pinned)

            // Which ones are grayed depends on where they now are.
            DispatchQueue.main.async { self?.apply(animated: false) }
        }
    }

    private static func fit(_ count: Int) -> String {
        switch count {
        case 0: "None fit"
        case 1: "One fits"
        default: "\(count) fit"
        }
    }

    // MARK: Changing

    private func pin(_ key: BarKey) {
        BarKey.pinned.append(key)
        apply(animated: true)
    }

    private func unpin(_ key: BarKey) {
        BarKey.pinned.removeAll { $0 == key }
        apply(animated: true)
    }

    private func apply(animated: Bool) {
        let pinned = BarKey.pinned

        var snapshot = NSDiffableDataSourceSnapshot<Section, BarKey>()
        snapshot.appendSections([.pinned])
        snapshot.appendItems(pinned, toSection: .pinned)

        for group in BarKey.Group.allCases {
            let keys = BarKey.pinnable.filter { $0.group == group && !pinned.contains($0) }
            guard !keys.isEmpty else { continue }

            snapshot.appendSections([.group(group)])
            snapshot.appendItems(keys, toSection: .group(group))
        }

        // Rows that stay put still need redrawing: whether one is grayed depends on its place.
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(existing.contains))

        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apply(animated: false)
    }

    override func viewWillTransition(
        to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)

        // Rotating changes how many fit.
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.apply(animated: false)
            self?.reloadFooters()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Only now is there a window to measure the bar against.
        apply(animated: false)
        reloadFooters()
    }

    private func reloadFooters() {
        var snapshot = dataSource.snapshot()
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: UICollectionViewDelegate

    /// Tapping a key that isn't pinned pins it, as its add button does.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let key = dataSource.itemIdentifier(for: indexPath),
            dataSource.snapshot().sectionIdentifier(containingItem: key) != .pinned
        else { return }

        pin(key)
    }

    /// Keeps a dragged key among the pinned ones.
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
        atCurrentIndexPath currentIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard proposedIndexPath.section != 0 else { return proposedIndexPath }

        let last = max(0, collectionView.numberOfItems(inSection: 0) - 1)
        return IndexPath(item: last, section: 0)
    }
}
