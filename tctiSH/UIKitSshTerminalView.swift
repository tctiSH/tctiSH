//
//  UIKitSshTerminalView.swift
//  iOS
//
//  Created by Miguel de Icaza on 4/22/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
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
        super.init (frame: frame, font: UIFont(name: "Menlo-Regular", size: 18))
        terminalDelegate = self
        
        // FIXME: This is just a workaround until we have vm image save/loading.
        // Set up a timer to periodically poll our connection.
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        subscription = timer?.sink(receiveValue: { _ in
            if self.connected {
                self.timer?.upstream.connect().cancel()
            } else {
                self.connect()
            }
        })
        
        shell = try? SSHShell(sshLibrary: Libssh2.self,
                                  host: "localhost",
                                  port: 10022,
                                  terminal: "xterm-256color")
        shell?.log.enabled = true
    }
  
    
    
    func connect()
    {
        if let s = shell {
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

                        //DispatchQueue.main.sync {
                            self.feed(byteArray: chunk)
                        //}
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
