//
// Terminal view for tctiSH.
// Provides an internal SSH connection to our lightweight VM.
//
//  Copyright © 2022 Kate Temkin <k@ktemkin.com>.
//  Copyright © 2020 Miguel de Icaza.
//

import Foundation
import UIKit
import SwiftTerm
import SwiftSH
import Combine


/// Termainal view that behaves like an Xterm into our linux environment.
public class TctiTermView: TerminalView, TerminalViewDelegate {
    var shell: SSHShell?
    var authenticationChallenge: AuthenticationChallenge?
    var connected : Bool = false
    
    /// Timer that is used to poll for connections if our connection drops.
    private var timer: Publishers.Autoconnect<Timer.TimerPublisher>? = nil
    private var subscription: AnyCancellable? = nil
    
    public override init (frame: CGRect)
    {
        super.init (frame: frame, font: UIFont(name: "Menlo-Regular", size: 14))
        self.terminalDelegate = self
        
        // Set up a timer to periodically poll our VM until it's ready for connection.
        timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
        subscription = timer?.sink(receiveValue: { _ in
            if self.connected {
                self.timer?.upstream.connect().cancel()
            } else {
                self.connect()
            }
        })
        
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
        shell?.log.enabled = false
        
        self.bounces = false
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
                if let error = error {
                    //self.feed(text: "[ERROR?] \(error)\n")
                } else {
                    self.connected = true

                    // Mark us as no longer attempting boot.
                    UserDefaults.standard.set(false, forKey: "attempting_boot")

                    let t = self.getTerminal()
                    s.setTerminalSize(width: UInt (t.cols), height: UInt (t.rows))

                    // At this point 
                    t.updateFullScreen()
                }
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // TerminalViewDelegate conformance
    public func scrolled(source: TerminalView, position: Double) {
        //
    }
    
    public func setTerminalTitle(source: TerminalView, title: String) {
        //
    }
    
    
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if let s = shell {
            s.setTerminalSize(width: UInt (newCols), height: UInt (newRows))
        }
    }
    
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        shell?.write(Data (data)) { err in
            if let e = err {
                print ("Error sending \(e)")
            }
        }
    }
    
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        
    }

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
