//
//  FindBar.swift
//  The find bar, for finding text in a TTY's history.
//
//  Copyright © 2026 Ara Adkins.
//

import SwiftTerm
import UIKit

/// A bar over the top of the terminal for finding text in it: a search field,
/// Previous and Next buttons, and the current match's position among all the
/// matches.
///
/// The search starts at the bottom and works up through the scrollback, because
/// the most recent match is usually the one the user wants. The current match
/// is shown as the terminal's selection.
final class FindBar: UIView, UITextFieldDelegate {

    static let height: CGFloat = 44

    /// The terminal being searched.
    weak var terminal: TerminalView?

    /// Called when the Done button is tapped or Esc is pressed.
    var close: () -> Void = {}

    private let capsule = KeyBar.makeCapsule()
    private let field = UISearchTextField()
    private let count = UILabel()
    private let previousButton = UIButton(configuration: .plain())
    private let nextButton = UIButton(configuration: .plain())
    private let done = UIButton(configuration: .plain())

    /// A search scheduled to run after a short pause in typing. Each keystroke
    /// cancels it and schedules a new one.
    private var pending: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)

        overrideUserInterfaceStyle = .dark
        tintColor = Accent.custom
        addSubview(capsule)

        field.placeholder = "Find"
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.delegate = self
        field.backgroundColor = .clear
        field.addAction(UIAction { [weak self] _ in self?.typed() }, for: .editingChanged)

        count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        count.textColor = .secondaryLabel
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        for (button, symbol, label) in [
            (previousButton, "chevron.up", "Previous Match"),
            (nextButton, "chevron.down", "Next Match"),
            (done, "xmark", "Done"),
        ] {
            button.configuration?.image = UIImage(systemName: symbol)
            button.configuration?.baseForegroundColor = .label
            button.accessibilityLabel = label
            KeyBar.hover(button)
        }
        previousButton.addAction(
            UIAction { [weak self] _ in self?.step(back: true) }, for: .touchUpInside)
        nextButton.addAction(
            UIAction { [weak self] _ in self?.step(back: false) }, for: .touchUpInside)
        done.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [field, count, previousButton, nextButton, done])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(
                equalTo: capsule.contentView.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 40),
            nextButton.widthAnchor.constraint(equalToConstant: 40),
            done.widthAnchor.constraint(equalToConstant: 40),
        ])

        refreshCount(found: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this bar is built in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds
        if #unavailable(iOS 26.0) {
            capsule.layer.cornerRadius = bounds.height / 2
        }
    }

    /// Starts a new search, putting `term` in the field if one is given, and
    /// gives the field the keyboard.
    func begin(with term: String? = nil) {
        terminal?.clearSearch()
        if let term {
            field.text = term
        }
        _ = field.becomeFirstResponder()
        search()
    }

    /// Whether the field has the keyboard.
    var isTyping: Bool { field.isFirstResponder }

    /// Gives the field the keyboard and selects its text, so that typing
    /// replaces it. ⌘F does this when the bar is already open.
    func focus() {
        _ = field.becomeFirstResponder()
        field.selectAll(nil)
    }

    /// Ends the search: cancels any pending search, clears the selection that
    /// marks the match, and takes the keyboard from the field.
    func end() {
        pending?.cancel()
        terminal?.clearSearch()
        _ = field.resignFirstResponder()
    }

    /// Esc to close the bar, and on iPhone, ⌘G and ⌘⇧G for the next and
    /// previous match. On iPad, those two come from Edit > Find in the menu bar
    /// instead.
    override var keyCommands: [UIKeyCommand]? {
        let done = UIKeyCommand(
            title: "Done", action: #selector(escape), input: UIKeyCommand.inputEscape)
        guard traitCollection.userInterfaceIdiom == .phone else { return [done] }
        return [
            done,
            UIKeyCommand(
                title: "Previous Match", action: #selector(previousMatch), input: "g",
                modifierFlags: [.command, .shift]),
            UIKeyCommand(
                title: "Next Match", action: #selector(nextMatch), input: "g",
                modifierFlags: .command),
        ]
    }

    @objc private func escape() { close() }
    @objc private func previousMatch() { step(back: true) }
    @objc private func nextMatch() { step(back: false) }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        step(back: true)
        return false
    }

    // MARK: Searching

    private var term: String { field.text ?? "" }

    private func typed() {
        pending?.cancel()
        let search = DispatchWorkItem { [weak self] in self?.search() }
        pending = search
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: search)
    }

    /// Searches for the text now in the field. If the text has changed and
    /// there is a current match, SwiftTerm first looks for the new text at that
    /// match, so that typing more characters refines the match in place. If it
    /// doesn't match there, the search continues upward from the current match,
    /// or from the bottom if there is no current match.
    private func search() {
        pending = nil
        guard !term.isEmpty, let terminal else {
            terminal?.clearSearch()
            refreshCount(found: true)
            return
        }
        refreshCount(found: terminal.findPrevious(term))
    }

    /// Moves to the match before the current one (further up) if `back` is
    /// true, and to the match after it otherwise.
    func step(back: Bool) {
        pending?.cancel()
        guard !term.isEmpty, let terminal else { return }
        let found = back ? terminal.findPrevious(term) : terminal.findNext(term)
        refreshCount(found: found)
    }

    private func refreshCount(found: Bool) {
        guard !term.isEmpty, let terminal else {
            count.text = nil
            count.isHidden = true
            previousButton.isEnabled = false
            nextButton.isEnabled = false
            return
        }

        let (index, total) = terminal.searchMatchSummary(term)
        count.isHidden = false
        count.text = !found || total == 0 ? "No matches" : "\(index) of \(total)"
        previousButton.isEnabled = total > 0
        nextButton.isEnabled = total > 0
    }
}
