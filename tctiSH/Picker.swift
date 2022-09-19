//
//  Picker.swift
//  In-band file picker consructs.
//
//  Created by Kate Temkin on 9/9/22.
//  Copyright (c) 2022 Kate Temkin.
//

import UIKit
import Foundation

/// Picker for allowing the user to select a single directory.
class DirectoryPicker : NSObject, UIDocumentPickerDelegate  {

    /// The result of our selection; the URLs picked.
    /// Protected by selectionCondition.lock().
    private var selectedURLs : [URL]?

    /// CV that indicates when selection is complete.
    private var selectionCondition : NSCondition

    public override init() {
        selectionCondition = NSCondition()
        super.init()
    }


    /// Pops up a dialog that allows the user to select a directory.
    /// Returns [] on failure/cancel, or [<url>] on success.
    public static func popUpModalDialog() -> [URL] {

        // Create a simple directory picker...
        let picker = DirectoryPicker()

        // ... and show it.
        picker.show()
        return picker.getSelectedFiles() ?? []
    }


    /// Shows the active file picker, requesting user input.
    public func show() {
        DispatchQueue.main.async {

            // Set up a file picker to find a folder...
            let documentPicker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
            documentPicker.delegate = self

            // ... and pop up that picker.
            let viewController = ViewController.getCurrent()!
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
    private func handleDocumentPickerResult(urls: [URL]) {
        selectionCondition.lock()
        defer { selectionCondition.unlock() }

        // Store our selection.
        selectedURLs = urls
        selectionCondition.broadcast()
    }

    /// Callback that occurs when the user has picked a document.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        handleDocumentPickerResult(urls: urls)
    }

    /// Callback that occurs if the user cancels document picking.
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        handleDocumentPickerResult(urls: [])
    }
}
