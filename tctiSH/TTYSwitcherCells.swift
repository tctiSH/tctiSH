//
//  TTYSwitcherCells.swift
//  The TTY switcher's cards and pills.
//
//  Copyright © 2026 Ara Adkins.
//

import UIKit

// MARK: - The name

/// Shows a TTY's name, followed by its console if it goes by another name, and
/// then its status icons.
final class TTYNameView: UIStackView {

    private let name = UILabel()
    private let device = UILabel()
    let status = TTYStatusView()

    init(font: UIFont) {
        super.init(frame: .zero)
        axis = .horizontal
        spacing = 5

        // The name and console share a baseline, and the icons are centered on the line: on the
        // baseline, the small unseen-output dot sat below the middle of the text.
        alignment = .center
        let names = UIStackView(arrangedSubviews: [name, device])
        names.axis = .horizontal
        names.alignment = .firstBaseline
        names.spacing = spacing

        name.font = font
        name.textColor = .label
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        device.font = .monospacedSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
        device.textColor = .secondaryLabel
        device.setContentHuggingPriority(.required, for: .horizontal)

        status.pointSize = font.pointSize
        status.alignment = .center

        [names, status].forEach(addArrangedSubview)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used; this view is built in code")
    }

    func show(_ tty: TTY) {
        name.text = tty.name
        device.text = tty.name == tty.device ? nil : tty.device
        device.isHidden = device.text == nil
        status.show(tty.statuses)
    }

    /// The VoiceOver label for a TTY: its name, its console if it goes by
    /// another name, and its statuses.
    static func accessibilityLabel(for tty: TTY) -> String {
        var parts = [tty.name]
        if let device = tty.device, device != tty.name {
            parts.append(device)
        }
        parts += tty.statuses.map(\.accessibilityLabel)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Hovering

/// Enlarges a cell slightly and lightens it while the pointer is over it. The
/// amount of lightening is computed from the color being lightened (for a card,
/// its picture's average color), so that the change is equally visible on any
/// color; a cell too light to lighten visibly is darkened instead.
///
/// The view that is scaled is `body`, which holds everything the cell shows,
/// rather than the content view. UIKit sets the content view's frame when it
/// lays out the cell, and setting a frame on a view with a scale transform
/// resizes its contents to compensate, which would undo the scale.
private final class HoverResponse: NSObject {

    /// The view that holds everything the cell shows, and that is scaled while
    /// the pointer is over the cell.
    let body = UIView()

    private weak var cell: UICollectionViewCell?
    private let overlay: UIView
    private let scale: CGFloat
    private let base: () -> UIColor
    private var hovering = false

    /// Makes `cell` respond to the pointer. `overlay` is a view that the cell
    /// lays over the area that should lighten, and `base` returns that area's
    /// predominant color, from which the overlay's color and opacity are
    /// computed. `scale` is how much `body` grows.
    init(
        cell: UICollectionViewCell, overlay: UIView, scale: CGFloat,
        base: @escaping () -> UIColor
    ) {
        self.cell = cell
        self.overlay = overlay
        self.scale = scale
        self.base = base
        super.init()

        cell.contentView.addSubview(body)

        overlay.alpha = 0
        overlay.isUserInteractionEnabled = false
        cell.addGestureRecognizer(
            UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
    }

    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        switch hover.state {
        case .began, .changed: set(true)
        default: set(false)
        }
    }

    /// Makes `body` fill the content view. Set by bounds and center rather than
    /// frame, because setting a frame on a view with a scale transform resizes
    /// its contents to compensate.
    func layOut() {
        guard let content = cell?.contentView else { return }
        body.bounds = content.bounds
        body.center = CGPoint(x: content.bounds.midX, y: content.bounds.midY)
    }

    /// Starts or ends the hover effect, unless it is already in that state. The
    /// hover recognizer reports a change each time the pointer moves within the
    /// cell, and those reports must not restart the animation.
    func set(_ hovering: Bool) {
        guard hovering != self.hovering else { return }
        self.hovering = hovering

        var strength: CGFloat = 0
        if hovering {
            let (color, alpha) = SwitcherBackground.hoverOverlay(over: base())
            overlay.backgroundColor = color
            strength = alpha
        }
        UIView.animate(
            withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.body.transform =
                hovering ? CGAffineTransform(scaleX: self.scale, y: self.scale) : .identity
            self.overlay.alpha = strength
        }
    }

    /// Ends the hover effect immediately, without animating, for a cell being
    /// reused.
    func reset() {
        hovering = false
        body.transform = .identity
        overlay.alpha = 0
    }
}

// MARK: - Cards

/// An unpinned user TTY as a card: a picture of its screen that is kept up to
/// date, a close button, and its name underneath.
final class TTYCardCell: UICollectionViewCell {

    static let labelHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 12

    /// How far the selection ring extends beyond the picture. The cell leaves
    /// this much room around the picture, because when a cell is lifted for its
    /// context menu, the lifted view is clipped to the cell's bounds.
    static let ringOutset: CGFloat = 5

    /// The picture's faint edge.
    private static let edge = UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 1 : 0, alpha: 0.15)
    }

    /// Called by the close button and the Close accessibility action. The
    /// switcher sets it to ask for confirmation, then close the TTY.
    var close: () -> Void = {}

    let thumbnail = UIImageView()
    private let ring = UIView()
    private let hoverOverlay = UIView()
    private var hover: HoverResponse!
    private let closeButton = UIButton(configuration: .plain())
    private let label = TTYNameView(font: .preferredFont(forTextStyle: .body))

    /// The TTY the card shows, and the TTY's `outputCount` when the picture was
    /// last drawn, or nil if it hasn't been drawn.
    private(set) weak var tty: TTY?
    private var drawnAt: Int?

    /// The picture's average color, cached with the picture it was computed
    /// from.
    private var predominant: (image: UIImage, color: UIColor)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        hover = HoverResponse(cell: self, overlay: hoverOverlay, scale: 1.03) {
            [unowned self] in predominantColor()
        }
        let body = hover.body

        // A ring around the picture marks the selected TTY, as in Safari's tab overview.
        ring.layer.cornerRadius = Self.cornerRadius + 4
        ring.layer.cornerCurve = .continuous
        ring.layer.borderWidth = 3
        ring.isHidden = true
        body.addSubview(ring)

        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = Self.cornerRadius
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.layer.borderWidth = 1
        thumbnail.layer.borderColor = Self.edge.resolvedColor(with: traitCollection).cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: Self, _) in
            cell.thumbnail.layer.borderColor =
                Self.edge.resolvedColor(with: cell.traitCollection).cgColor
        }
        body.addSubview(thumbnail)

        hoverOverlay.layer.cornerRadius = Self.cornerRadius
        hoverOverlay.layer.cornerCurve = .continuous
        body.addSubview(hoverOverlay)

        closeButton.configuration?.image = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
                .applying(
                    UIImage.SymbolConfiguration(paletteColors: [
                        .white, UIColor.black.withAlphaComponent(0.55),
                    ])))
        closeButton.accessibilityLabel = "Close"
        closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        KeyBar.hover(closeButton)
        body.addSubview(closeButton)

        label.alignment = .center
        body.addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this cell is built in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hover.layOut()

        let bounds = hover.body.bounds
        let outset = Self.ringOutset
        thumbnail.frame = CGRect(
            x: outset, y: outset, width: max(0, bounds.width - outset * 2),
            height: max(0, bounds.height - outset - Self.labelHeight))
        ring.frame = thumbnail.frame.insetBy(dx: -outset, dy: -outset)
        hoverOverlay.frame = thumbnail.frame

        let side: CGFloat = 40
        closeButton.frame = CGRect(
            x: thumbnail.frame.maxX - side, y: thumbnail.frame.minY, width: side, height: side)

        let size = label.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: Self.labelHeight),
            withHorizontalFittingPriority: .fittingSizeLevel, verticalFittingPriority: .required)
        let width = min(size.width, bounds.width)
        label.frame = CGRect(
            x: (bounds.width - width) / 2, y: thumbnail.frame.maxY + 8, width: width,
            height: Self.labelHeight - 8)

        // The thumbnail's size is known only once it is laid out, so redraw the picture if it was
        // drawn at a different width.
        refreshThumbnail(force: thumbnail.image?.size.width != thumbnail.bounds.width)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hover.reset()
    }

    func show(_ tty: TTY, selected: Bool) {
        if self.tty !== tty {
            self.tty = tty
            drawnAt = nil
            thumbnail.image = nil
        }
        label.show(tty)
        // The name may have changed, and the label is sized in `layoutSubviews()`, so lay the cell
        // out again.
        setNeedsLayout()
        ring.isHidden = !selected
        ring.layer.borderColor = Accent.color.cgColor
        accessibilityLabel = TTYNameView.accessibilityLabel(for: tty)
        accessibilityValue = selected ? "Selected" : nil
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Close") { [weak self] _ in
                self?.close()
                return true
            }
        ]
        refreshThumbnail(force: false)
    }

    /// The card's outline, for the lift preview and its context menu: the
    /// picture (or the ring around it, if the TTY is selected) and the name
    /// under it.
    var previewPath: UIBezierPath {
        let body = hover.body
        let picture = ring.isHidden ? thumbnail.frame : ring.frame
        let radius = ring.isHidden ? thumbnail.layer.cornerRadius : ring.layer.cornerRadius
        let path = UIBezierPath(roundedRect: convert(picture, from: body), cornerRadius: radius)

        let name = convert(label.frame.insetBy(dx: -8, dy: -2), from: body)
        path.append(UIBezierPath(roundedRect: name, cornerRadius: name.height / 2))
        return path
    }

    /// Redraws the picture if the TTY's `outputCount` has changed since it was
    /// last drawn, through output, a resize or a font size change, or always if
    /// `force` is true.
    func refreshThumbnail(force: Bool) {
        guard let tty, let view = tty.view, thumbnail.bounds.width > 0 else { return }
        guard force || drawnAt != tty.outputCount else { return }

        drawnAt = tty.outputCount
        thumbnail.backgroundColor = view.nativeBackgroundColor
        thumbnail.image = TerminalThumbnail.render(
            view, width: thumbnail.bounds.width, scale: traitCollection.displayScale)
    }

    /// The current picture's average color, from which the hover overlay is
    /// computed. It is computed again only after the picture is redrawn.
    private func predominantColor() -> UIColor {
        let background = thumbnail.backgroundColor ?? .black
        guard let image = thumbnail.image else { return background }
        if let predominant, predominant.image === image {
            return predominant.color
        }
        let color = TerminalThumbnail.averageColor(of: image, over: background)
        predominant = (image, color)
        return color
    }
}

// MARK: - Pills

/// A system or pinned TTY as a compact pill: a lock or pin icon, its name, and
/// its status icons.
final class TTYPillCell: UICollectionViewCell {

    /// The color behind the pill, which shows through its translucent fill and
    /// from which the hover overlay is computed.
    var surface: UIColor = .black {
        didSet { background.backgroundColor = fillColor.withAlphaComponent(Self.fill) }
    }

    private static let fill = 0.12

    /// What the fill tints the surface with.
    private var fillColor: UIColor {
        TerminalTheme.interfaceStyle(over: surface) == .dark ? .white : .black
    }

    private let background = UIView()
    private let hoverOverlay = UIView()
    private var hover: HoverResponse!
    private let icon = UIImageView()
    private let label = TTYNameView(font: .preferredFont(forTextStyle: .body))

    override init(frame: CGRect) {
        super.init(frame: frame)
        hover = HoverResponse(cell: self, overlay: hoverOverlay, scale: 1.04) {
            [unowned self] in ColorMath.blend(fillColor, alpha: Self.fill, over: surface)
        }
        let body = hover.body

        background.backgroundColor = fillColor.withAlphaComponent(Self.fill)
        background.layer.cornerCurve = .continuous
        body.addSubview(background)

        hoverOverlay.layer.cornerCurve = .continuous
        background.addSubview(hoverOverlay)

        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            textStyle: .footnote, scale: .medium)
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: body.centerYAnchor),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this cell is built in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hover.layOut()
        background.frame = hover.body.bounds
        background.layer.cornerRadius = hover.body.bounds.height / 2
        hoverOverlay.frame = background.bounds
        hoverOverlay.layer.cornerRadius = background.layer.cornerRadius
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hover.reset()
    }

    /// The pill's outline, for the lift preview and its context menu.
    var previewPath: UIBezierPath {
        let shape = convert(background.frame, from: hover.body)
        return UIBezierPath(roundedRect: shape, cornerRadius: shape.height / 2)
    }

    func show(_ tty: TTY, selected: Bool) {
        icon.image = UIImage(systemName: tty.isSystem ? "lock.fill" : "pin.fill")
        label.show(tty)

        background.layer.borderWidth = selected ? 2 : 0
        background.layer.borderColor = Accent.color.cgColor

        accessibilityLabel = TTYNameView.accessibilityLabel(for: tty)
        accessibilityValue = [tty.isSystem ? "Locked" : "Pinned", selected ? "Selected" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
