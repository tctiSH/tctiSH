//
//  ThemeThumbnailProvider.swift
//  The thumbnail Files shows for a .tctheme file.
//
//  Copyright © 2026 Ara Adkins.
//

import QuickLookThumbnailing
import UIKit

/// Draws a `.tctheme` file's thumbnail: the theme's swatch as in Settings, as
/// large as Files asks for.
final class ThemeThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let theme: TerminalTheme
        do {
            theme = try TerminalTheme(contentsOf: request.fileURL)
        } catch {
            handler(nil, error)
            return
        }

        // At the swatch's 3:2, as wide as fits.
        let maximum = request.maximumSize
        let width = min(maximum.width, maximum.height * 3 / 2)
        let size = CGSize(width: width, height: width * 2 / 3)
        let reply = QLThumbnailReply(contextSize: size) {
            theme.drawSwatch(in: CGRect(origin: .zero, size: size))
            return true
        }
        handler(reply, nil)
    }
}
