//
//  Picker.swift
//  In-band file picker consructs.
//
//  Created by Kate Temkin on 9/9/22.
//  Copyright (c) 2022 Kate Temkin.
//

import UIKit
import Foundation
import UniformTypeIdentifiers

/// Picker for allowing the user to select a single directory.
class DirectoryPicker: NSObject, UIDocumentPickerDelegate {

    /// The result of our selection; the URLs picked.
    /// Protected by selectionCondition.lock().
    private var selectedURLs: [URL]?

    /// CV that indicates when selection is complete.
    private var selectionCondition: NSCondition

    public override init() {
        selectionCondition = NSCondition()
        super.init()
    }

    /// Pops up a dialog that allows the user to select a directory.
    /// Returns [] on failure/cancel, or [<url>] on success.
    public class func popUpModalDialog() -> [URL] {

        // Create a simple directory picker...
        let picker = DirectoryPicker()

        // ... and show it.
        picker.show()
        return picker.getSelectedFiles() ?? []
    }

    /// The content types this picker offers; overridden by subclasses.
    class var contentTypes: [UTType] { [.folder] }

    /// Shows the active file picker, requesting user input.
    public func show() {
        DispatchQueue.main.async {

            // Set up a file picker to find a folder...
            //
            // `asCopy: false` is what makes this open in place rather than
            // duplicating the selection into our container, which is the whole
            // point: the user picks a directory to share with the guest.
            let documentPicker = UIDocumentPickerViewController(
                forOpeningContentTypes: Self.contentTypes, asCopy: false)
            documentPicker.delegate = self

            // ... and pop up that picker, if there's anything to pop it up
            // from.
            guard let viewController = ViewController.getCurrent() else {
                self.handleDocumentPickerResult(urls: [])
                return
            }
            viewController.present(documentPicker, animated: true)
        }
    }

    /// Retreives any files selected by the user.
    /// Typically called in a blocking manner.
    func getSelectedFiles(blocking: Bool = true) -> [URL]? {
        selectionCondition.lock()
        defer { selectionCondition.unlock() }

        // If we already have an answer, return.
        if let urls = selectedURLs {
            return urls
        }

        // Otherwise, wait (if required), and then return.
        if (blocking) {
            selectionCondition.wait()
        }
        return selectedURLs
    }

    /// Stores the result of a documentPicker event callback.
    fileprivate func handleDocumentPickerResult(urls: [URL]) {
        selectionCondition.lock()
        defer { selectionCondition.unlock() }

        // Store our selection.
        selectedURLs = urls
        selectionCondition.broadcast()
    }

    /// Callback that occurs when the user has picked a document.
    func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        handleDocumentPickerResult(urls: urls)
    }

    /// Callback that occurs if the user cancels document picking.
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        handleDocumentPickerResult(urls: [])
    }
}

/// Picker for allowing the user to select a single pairing file.
///
/// Pairing files are plists, but they arrive with assorted names and extensions
/// depending on how they were generated, so this accepts any file rather than
/// filtering them out of the user's view.
class PairingFilePicker: DirectoryPicker {

    override class var contentTypes: [UTType] { [.item] }

    /// Pops up a dialog that allows the user to select a pairing file,
    /// returning on failure/cancel, or [<url>] on success.
    public override class func popUpModalDialog() -> [URL] {
        let picker = PairingFilePicker()

        picker.show()
        return picker.getSelectedFiles() ?? []
    }
}
