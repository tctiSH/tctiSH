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
        
        // ... get a disk to run with ...
        let diskPath = getPersistentStore().path
            
        // ... and run QEMU.
        run_background_qemu(kernelPath, initrdPath, bundlePrefix, diskPath)
        
    }
    

    /// Returns the URL to a qcow image that will acts as our persistent store.
    /// TODO: figure out if we want to use qcow2, or if we should implement a different file backend?
    private func getPersistentStore() -> URL
    {
        // Figure out where our persistent store would be located.
        var targetURL = try! FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "disk.qcow"),
            create: false)
        
        // Scult our filename so it ends in "disk.qcow".
        targetURL.appendPathComponent("disk")
        targetURL.appendPathExtension("qcow")

        // If it doesn't exist, create a new copy based on our empty disk.
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            let emptyDiskURL = Bundle.main.url(forResource: "empty", withExtension: "qcow")
            try! FileManager.default.copyItem(at: emptyDiskURL!, to: targetURL)
        }
    
        return targetURL
    }
    
}
