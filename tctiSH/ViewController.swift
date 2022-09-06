//
//  tctiSH primary view controller.
//  Currently, primarily hosts our terminal.
//
//  Created by Miguel de Icaza on 3/19/19.
//  Modified for tctiSH by @ktemkin.
//
//  Copyright © 2022 Kate Temkin. All rights reserved.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import UIKit
import SwiftTerm

class ViewController: UIViewController {
    var tv: TerminalView!
    
    let padding: CGFloat = 7

    /// Sequence used to clear our terminal.
    let terminalClearSequence : ArraySlice<UInt8> = [27, 91, 72, 27, 91, 74]
    
    var useAutoLayout: Bool {
        get { false }
    }
    
    func makeFrame (keyboardDelta: CGFloat, _ fn: String = #function, _ ln: Int = #line) -> CGRect
    {
        if useAutoLayout {
            return CGRect.zero
        } else {
            return CGRect (x: view.safeAreaInsets.left + padding,
                           y: view.safeAreaInsets.top + padding,
                           width: view.frame.width - view.safeAreaInsets.left - view.safeAreaInsets.right - (padding * 2),
                           height: view.frame.height - view.safeAreaInsets.top - keyboardDelta - (padding * 2))
        }
    }
    
    func setupKeyboardMonitor ()
    {
        if #available(iOS 15.0, *), useAutoLayout {
            tv.translatesAutoresizingMaskIntoConstraints = false
            tv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).isActive = true
            tv.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true
            tv.rightAnchor.constraint(equalTo: view.rightAnchor).isActive = true
            
            tv.keyboardLayoutGuide.topAnchor.constraint(equalTo: tv.bottomAnchor).isActive = true
        } else {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillShow),
                name: UIWindow.keyboardWillShowNotification,
                object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillHide),
                name: UIWindow.keyboardWillHideNotification,
                object: nil)
        }
    }
    
    var keyboardDelta: CGFloat = 0
    @objc private func keyboardWillShow(_ notification: NSNotification) {
        guard let keyboardValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        
        let keyboardScreenEndFrame = keyboardValue.cgRectValue
        let keyboardViewEndFrame = view.convert(keyboardScreenEndFrame, from: view.window)
        keyboardDelta = keyboardViewEndFrame.height
        tv.frame = makeFrame(keyboardDelta: keyboardViewEndFrame.height)
    }
    
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        tv.frame = CGRect (origin: tv.frame.origin, size: size)
    }
    
    @objc private func keyboardWillHide(_ notification: NSNotification) {
        //let key = UIResponder.keyboardFrameBeginUserInfoKey
        keyboardDelta = 0
        tv.frame = makeFrame(keyboardDelta: 0)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Start up our terminal emulator, which will display our actual terminal.
        tv = TctiTermView(frame: makeFrame (keyboardDelta: 0))
        view.addSubview(tv)


        // If JIT hacks are running, give the user a nice message.
        if AppDelegate.usingJitHacks {
            NSLog("JIT hacks online.")
            tv.feed(text: "[Using full-JIT for magic speed! 🐆]\r\n\r\n")
        }


        // If we're doing a recovery boot by user choice, provide a message letting the
        // user know that this will take a hot moment.
        if UserDefaults.standard.string(forKey: "resume_behavior") == "recovery_boot" {
            tv.feed(text: "(Recovery booting; startup will take a bit.)\r\n\r\n")
        }


        // If we're forcing a recovery boot by something other than user choice, provide
        // a message letting the user know
        else if AppDelegate.forceRecoveryBoot {

            tv.feed(text: "It seems like our last attempt at resuming\r\n")
            tv.feed(text: "might not have gone so well. We'll recover\r\n")
            tv.feed(text: "by restarting things the slow way.\r\n\r\n")

            tv.feed(text: "This will take ~20 seconds or so.\r\n\r\n")

        } else {

            // Provide some filler content,to ensure the ScrollView starts with something in it;
            // and then issue a "clear", so it's off the backlog. This is a cheap, hackish way of
            // getting there to be something in the UIScrollView buffer; which means that we avoid
            // the nasty "transparent" boxes it tries to squish at either end if there's not enough content.
            //
            // We could squish in spacer controls; but these do the same thing and don't muck up the
            // position math SwiftTerm does later.
            for _ in 0...25 {
                tv.feed(text:"\n")
            }

        }

        setupKeyboardMonitor()
        tv.becomeFirstResponder()
        
    }
    
    override func viewWillLayoutSubviews() {
        if useAutoLayout, #available(iOS 15.0, *) {
        } else {
            tv.frame = makeFrame (keyboardDelta: keyboardDelta)
        }
    }
}

