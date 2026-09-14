//
//  FileDownloader.swift
//  Fetching a file to disk, with progress.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation

/// Downloads one file at a time, reporting bytes as they land through the
/// delegate rather than a completion handler.
///
/// One download at a time; `download` blocks until it's done.
///
/// Foundation only, so it knows nothing about developer disk images or StikJIT,
/// which means it can be compiled and run on a Mac against the real URLs.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 1800
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// State for the transfer currently in flight. Written by the caller before
    /// the task starts and read on the delegate queue afterwards; the semaphore
    /// orders the handover back.
    private var destination: URL?
    private var onProgress: ((Int64, Int64) -> Void)?
    private var failure: Error?
    private var done: DispatchSemaphore?

    func finish() {
        session.finishTasksAndInvalidate()
    }

    /// Blocking. The caller is already on a background queue.
    ///
    /// `progress` receives bytes rather than a fraction, and an expected count
    /// of -1 when the server won't say how big the file is, which happens
    /// whenever the response is gzipped, since the decompressed length isn't
    /// known in advance. Whether that's worth drawing a bar for is the caller's
    /// decision, not this type's.
    func download(
        _ url: URL, to destination: URL,
        progress: @escaping (_ written: Int64, _ expected: Int64) -> Void
    ) throws {
        let done = DispatchSemaphore(value: 0)

        self.destination = destination
        self.onProgress = progress
        self.failure = nil
        self.done = done

        defer {
            self.destination = nil
            self.onProgress = nil
            self.done = nil
        }

        session.downloadTask(with: url).resume()
        done.wait()

        if let failure { throw failure }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temporary file is deleted the moment this returns, so the move
        // has to happen here and not in didCompleteWithError.
        do {
            guard let destination else {
                throw DownloadError.message("finished a download nobody asked for")
            }

            guard let http = downloadTask.response as? HTTPURLResponse else {
                throw DownloadError.message("no response for \(destination.lastPathComponent)")
            }

            guard (200..<300).contains(http.statusCode) else {
                throw DownloadError.message(
                    "HTTP \(http.statusCode) for \(destination.lastPathComponent)")
            }

            let manager = FileManager.default
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { failure = error }
        done?.signal()
    }

    enum DownloadError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }
}
