//
//  QEMULauncher
//  Swift interfacing code for launching our internal QEMU.
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
        
        // ... create a temporary copy of our starting memory state...
        let memstatePath = createTemporaryCopy(ofResource: "memory_state", withExtension: "qcow").path
        
        NSLog(memstatePath)
        
        // ... and spawn our TCTI execution layer.
        run_background_qemu(kernelPath, initrdPath, bundlePrefix, memstatePath)
        
    }
    
    private func createTemporaryCopy(ofResource: String, withExtension: String) -> URL
    {
        // Find the file we're looking for...
        let sourceURL = Bundle.main.url(forResource: ofResource, withExtension: withExtension)
            
        // ... figure out were to put a tempoorary copy...
        var targetURL = URL(fileURLWithPath: NSTemporaryDirectory(),
                                            isDirectory: true)
        targetURL.appendPathComponent(ofResource)
        targetURL.appendPathExtension(withExtension)
        
        NSLog(targetURL.absoluteString)

        // ... and copy our file into it.
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        
        try! FileManager.default.copyItem(at: sourceURL!, to: targetURL)
    
        return targetURL
    }
    
}
