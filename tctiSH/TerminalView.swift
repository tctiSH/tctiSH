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


public class SshTerminalView: TerminalView, TerminalViewDelegate {
    var shell: SSHShell?
    var authenticationChallenge: AuthenticationChallenge?
    
    var connected : Bool = false
    
    
    private var timer: Publishers.Autoconnect<Timer.TimerPublisher>? = nil
    private var subscription: AnyCancellable? = nil
    
    public override init (frame: CGRect)
    {
        super.init (frame: frame, font: UIFont(name: "Menlo-Regular", size: 16))
        terminalDelegate = self
        
        layer.borderWidth = 5
        
        // FIXME: This is just a workaround until we have vm image save/loading.
        // Set up a timer to periodically poll our connection.
        timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
        subscription = timer?.sink(receiveValue: { _ in
            if self.connected {
                self.timer?.upstream.connect().cancel()
            } else {
                self.connect()
            }
        })
       
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
    }
    
    /// Sets up use of the user's theme.
    public func setUpTheming() {
        // FIXME: have this be user-specifiable
        let theme = DefaultThemes.solzariedDark
        self.installColors(theme.ansi)
        
        let t = getTerminal()
        
        t.installPalette(colors: theme.ansi)
        t.foregroundColor = theme.foreground
        t.backgroundColor = theme.background
        t.updateFullScreen()
        
        self.nativeBackgroundColor = makeUIColor(theme.background)
        self.nativeForegroundColor = makeUIColor(theme.foreground)
        self.layer.backgroundColor = makeUIColor(theme.background).cgColor
        self.layer.borderColor     = self.layer.backgroundColor
        self.layer.shadowColor     = self.layer.backgroundColor
        self.backgroundColor       = self.nativeBackgroundColor
        
        self.selectedTextBackgroundColor = makeUIColor (theme.selectionColor)
        self.caretColor = makeUIColor (theme.cursor)
    }
    
    
    private func makeUIColor(_ color: SwiftTerm.Color) -> UIColor
    {
        UIColor (red: CGFloat (color.red) / 65535.0,
                 green: CGFloat (color.green) / 65535.0,
                 blue: CGFloat (color.blue) / 65535.0,
                 alpha: 1.0)
    }
    
  
    func connect()
    {
        if let s = shell {
            setUpTheming()
            
            s.withCallback { [unowned self] (data: Data?, error: Data?) in
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
            .connect()
            .authenticate(.byPassword(username: "root", password: "toor"))
            .open { [unowned self] (error) in
                if let error = error {
                    //self.feed(text: "[ERROR?] \(error)\n")
                } else {
                    self.connected = true
                    
                    let t = self.getTerminal()
                    s.setTerminalSize(width: UInt (t.cols), height: UInt (t.rows))
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
