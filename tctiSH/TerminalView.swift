//
// Terminal view for tctiSH.
// Provides an internal SSH connection to our lightweight VM.
//
//  Copyright © 2022 Kate Temkin <k@ktemkin.com>.
//  Copyright © 2020 Miguel de Icaza.
//

import Foundation
import UIKit
import AVKit
import SwiftTerm
import SwiftSH
import Combine


/// Termainal view that behaves like an Xterm into our linux environment.
public class TctiTermView: TerminalView, TerminalViewDelegate {

    /// Interval at which we check for an SSH connection.
    private static var sshPollingInterval : TimeInterval = 1.5

    var shell: SSHShell?
    var authenticationChallenge: AuthenticationChallenge?
    var connected : Bool = false

    var pipController : AVPictureInPictureController?


    /// The current working directory, if one is known/available.
    private var _cwd : String?
    public var cwd : String? {
        get {
            return _cwd
        }
    }

    /// Set to true to enable SSH logging.
    private static var sshLoggingEnabled : Bool = false

    /// Timer that is used to poll for connections if our connection drops.
    private var timer: Publishers.Autoconnect<Timer.TimerPublisher>? = nil
    private var subscription: AnyCancellable? = nil

    public override init (frame: CGRect)
    {
        super.init (frame: frame, font: UIFont(name: "Menlo-Regular", size: 14))
        self.terminalDelegate = self

        // Handle settings changes.
        NotificationCenter.default.addObserver(self, selector: #selector(TctiTermView.applySettings), name: UserDefaults.didChangeNotification, object: nil)
        applySettings()

        // Create the SSH provider we'll use to connect to our instance.
        //
        // Using this over e.g. serial mode ensures we have an out-of-band
        // connection for e.g. terminal resizes to travel over, so SIGWINCH
        // works correctly.
        shell = try? SSHShell(sshLibrary: Libssh2.self,
                              host: "localhost",
                              port: 10022,
                              terminal: "xterm-256color")
        shell?.log.enabled = TctiTermView.sshLoggingEnabled

        // Make sure the terminal looks the way it should before anything's displayed.
        setUpTheming()

        // TODO: figure out if this should be automatic?
        start()
        
    }

    /// Starts the actual SSH terminal process.
    func start() {
        // Set up a timer to periodically poll our VM until it's ready for connection.
        timer = Timer.publish(every: TctiTermView.sshPollingInterval, on: .main, in: .common).autoconnect()
        subscription = timer?.sink(receiveValue: { _ in
            if self.connected {
                self.timer?.upstream.connect().cancel()
            } else {
                self.connect()
            }
        })

    }

    /// Forces the SSH session to reconnect.
    func forceReconnect() {

        // Force-recreate our SSH session...
        shell = try? SSHShell(sshLibrary: Libssh2.self,
                              host: "localhost",
                              port: 10022,
                              environment: [],
                              terminal: "xterm-256color")

        shell?.log.enabled = TctiTermView.sshLoggingEnabled

        // ... add a line-feed to ensure the cursor is in a valid drawing position, again...
        self.feed(text: "\r\n")

        // ... and reconnect.
        connect()
    }

    /// Callback notified each time a setting is changed.
    @objc
    func applySettings() {
        let std = UserDefaults.standard
        
        // Font size.
        var new_size = CGFloat(std.integer(forKey:"font_size"))
        if new_size == 0 {
            new_size = self.font.pointSize
        }
        if new_size != self.font.pointSize {
            self.font = UIFont(name: self.font.fontName, size: new_size) ?? self.font
        }
        
        // TODO: apply themes, here
        
    }
    
    func clear() {
        
        /// Sequence used to clear our terminal.
        let terminalClearSequence : ArraySlice<UInt8> = [27, 91, 72, 27, 91, 74]
        self.feed(byteArray: terminalClearSequence)
        
    }
    
    /// Sets up use of the user's theme.
    func setUpTheming() {
        // FIXME: have this be user-specifiable
        let theme = DefaultThemes.solzariedDark
        self.installColors(theme.ansi)
        
        let t = getTerminal()
        
        t.foregroundColor = theme.foreground
        t.backgroundColor = theme.background
        
        self.nativeBackgroundColor = makeUIColor(theme.background)
        self.nativeForegroundColor = makeUIColor(theme.foreground)
        self.layer.backgroundColor = makeUIColor(theme.background).cgColor
        self.layer.borderColor     = self.layer.backgroundColor
        self.layer.shadowColor     = self.layer.backgroundColor
        self.backgroundColor       = self.nativeBackgroundColor
        
        self.selectedTextBackgroundColor = makeUIColor (theme.selectionColor)
        self.caretColor = makeUIColor (theme.cursor)
    }
    
    
    // Helper that converts a SwiftTerm color into a UI color.
    private func makeUIColor(_ color: SwiftTerm.Color) -> UIColor
    {
        UIColor (red: CGFloat (color.red) / 65535.0,
                 green: CGFloat (color.green) / 65535.0,
                 blue: CGFloat (color.blue) / 65535.0,
                 alpha: 1.0)
    }
    
    func sshEventCallback(data: Data?, error: Data?) {
        if let d = data {
            let sliced = Array(d) [0...]

            // We chunk the processing of data, as the SSH library might have
            // received a lot of data, and we do not want the terminal to
            // parse it all, and then render, we want to parse in chunks to
            // give the terminal the chance to update the display as it goes.
            let blocksize = 1024
            var next = 0
            let last = sliced.endIndex

            while next < last {

                let end = min (next+blocksize, last)
                let chunk = sliced [next..<end]

                self.feed(byteArray: chunk)
                next = end
            }
        }

        
    }

    func connect()
    {
        if let s = shell {
            setUpTheming()
            
            s.withCallback { [unowned self] (data: Data?, error: Data?) in
                sshEventCallback(data: data, error: error)
            }
            .connect()
            .authenticate(.byPassword(username: "root", password: "toor"))
            .open { [unowned self] (error) in
                if error != nil {
                    NSLog("\(error)")
                    //self.feed(text: "[ERROR?] \(error)\n")
                } else {
                    // Mark us as no longer attempting boot.
                    self.connected = true
                    UserDefaults.standard.set(false, forKey: "attempting_boot")

                    // Inform the SSH server of our new size, so it can resize its PTY.
                    let t = self.getTerminal()
                    _ = s.setTerminalSize(width: UInt (t.cols), height: UInt (t.rows))

                    // Finally, update the terminal to display the new connection.
                    t.updateFullScreen()
                }
            }
        }
    }

    /// Compliance initializer for things that can do encoding/decoding.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Callback that occurs when the terminal is scrolled.
    /// Can be used to save the scrollback, if desired.
    public func scrolled(source: TerminalView, position: Double) {
        // Nothing to do here, yet.
    }


    /// Callback that occurs when the guest VM requests a terminal title change.
    public func setTerminalTitle(source: TerminalView, title: String) {
        NSLog("TODO: set app title to include: \(title)")
    }
    

    /// Callback that occurs when the terminal's effective area has changed.
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {

        // Pass through the size-change to our SSH session.
        _ = shell?.setTerminalSize(width: UInt(newCols), height: UInt(newRows))
    }


    /// Function usd to send data across our SSH connection.
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        shell?.write(Data (data)) { err in
            if let e = err {
                print ("Error sending \(e)")
            }
        }
    }

    /// Callback that occurs when we receive OSC 7, which indicates the current working directory.
    /// The default tctiSH setup's shell integration generates OSC-7 each time the prompt is issue.
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        _cwd = directory

        if let directory = directory {
            // Get a filename for our shared CWD file...
            let cwdFile = QEMUInterface.getLastCWDFile()

            // ... and write the CWD into it.
            try? directory.write(to: cwdFile, atomically: true, encoding: .utf8)
        }

    }

    /// Callback that occurs when the user clicks on a URL or link in the tctiSH scrollback.
    public func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        if let fixedup = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = NSURLComponents(string: fixedup) {
                if let nested = url.url {
                    UIApplication.shared.open (nested)
                }
            }
        }
    }

}
