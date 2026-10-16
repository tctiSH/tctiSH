//
//  ThemePreviewController.swift
//  What Quick Look shows for a .tctheme file.
//
//  Copyright © 2026 Ara Adkins.
//

import QuickLook
import UIKit

/// Shows a `.tctheme` file as its name and the visual preview that tctiSH's
/// theme editor shows, scaled up for the Files UI.
final class ThemePreviewController: UIViewController, QLPreviewingController {

    private static let textSize: CGFloat = 16

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            show(try TerminalTheme(contentsOf: url))
            handler(nil)
        } catch {
            handler(error)
        }
    }

    private func show(_ theme: TerminalTheme) {
        view.backgroundColor = .systemBackground

        let name = UILabel()
        name.text = theme.title
        name.font = .preferredFont(forTextStyle: .title2)
        name.adjustsFontForContentSizeCategory = true
        name.textAlignment = .center
        name.numberOfLines = 0

        let kind = UILabel()
        kind.text = "tctiSH Terminal Theme"
        kind.font = .preferredFont(forTextStyle: .subheadline)
        kind.adjustsFontForContentSizeCategory = true
        kind.textColor = .secondaryLabel
        kind.textAlignment = .center

        let preview = ThemePreview(theme: theme, textSize: Self.textSize)

        let stack = UIStackView(arrangedSubviews: [name, kind, preview])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.setCustomSpacing(20, after: kind)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: margins.trailingAnchor),
            name.widthAnchor.constraint(lessThanOrEqualTo: margins.widthAnchor),
        ])
    }
}
