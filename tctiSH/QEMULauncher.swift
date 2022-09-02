//
//  QEMULauncher.swift
//  tctiSH
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright ©2022 Kate Temkin. All rights reserved.
//

import Foundation


public class QEMULauncher {
    
    // Start our background QEMU thread.
    func startQemuThread() {
        
        // Figure out where our QEMU resources are...
        let bundlePrefix = Bundle.main.resourcePath!
        let kernelPath = bundlePrefix + "/" + "bzImage"
        let initrdPath = bundlePrefix + "/" + "initrd.img"
        
        // ... and spawn our TCTI execution layer.
        kernelPath.withCString { kernelStr in
            initrdPath.withCString { initrdStr in
                bundlePrefix.withCString { biosStr in
                    run_background_qemu(kernelStr, initrdStr, biosStr)
                }
            }
        }
        
    }
    
}
