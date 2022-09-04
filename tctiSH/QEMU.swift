//
//  QEMULauncher
//  Swift interfacing code for launching our internal QEMU.
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright ©2022 Kate Temkin. All rights reserved.
//

import Socket
import Foundation


/// Provides an interface for running / controlling a QEMU VM.
public class QEMUInterface {
    
    /// The port on which we connecto using the QEMU machine protocol.
    private static let monitorPort : Int32 = 10044
    
    /// Our QEMU human-readable protocol socket.
    var monitorSocket : Socket?
    
    /// Start our background QEMU thread.
    func startQemuThread() {
        
        // Figure out where our QEMU resources are...
        let bundlePrefix = Bundle.main.resourcePath!
        let kernelPath = bundlePrefix + "/" + "bzImage"
        let initrdPath = bundlePrefix + "/" + "initrd.img"
        
        // ... get a disk to run with ...
        let diskPath = getPersistentStore().path
        
        // ... figure out if we're using our A or B boot image ...
        let preferAImage = (getBootABStatus() == "A")
            
        // ... and run QEMU.
        run_background_qemu(kernelPath, initrdPath, bundlePrefix, diskPath, preferAImage);
    }
    
    /// Saves the state of the running QEMU instance.
    /// With no arguments, updates the Instant Boot cache.
    func saveState(tag: String) {
        issueMonitorCommand(command: "savevm \(tag)")
    }
    
    /// Saves the state of the running QEMU instance.
    /// With no arguments, loads from the Instant Boot cache.
    func loadState(tag: String) {
        issueMonitorCommand(command: "loadvm \(tag)")
        issueMonitorCommand(command: "c")
    }
    
    /// Saves the state of the running QEMU instance in a background-safe manner.
    /// With no arguments, loads from the Instant Boot cache.
    func performBackgroundSave() {
        let nextABStatus = getNextBootABStatus()
        let nextTag = "instantboot\(nextABStatus)"
        
        saveState(tag: nextTag)
        Thread.sleep(forTimeInterval: TimeInterval(2))
        setABBootStatus(status: nextABStatus)
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
    
    
    /// Returns the path to the file that contains our A/B boot status.
    private func getBootABStatusFile() -> URL
    {
        // Figure out where our persistent store would be located.
        var targetURL = try! FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "ab_status.conf"),
            create: true)
        
        // Scult our filename so it ends in "ab_status.conf".
        targetURL.appendPathComponent("ab_status")
        targetURL.appendPathExtension("conf")

        // If we don't have an AB status file, create one.
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            try! "A".write(to: targetURL, atomically: true, encoding: .utf8)
        }
    
        return targetURL
    }
    
    
    /// Returns whether we're booting using the 'A' or 'B' instant boot image.
    /// Allows us to have a fallback when saving.
    private func getBootABStatus() -> String {
        let configFile = getBootABStatusFile()
        return try! String(contentsOf: configFile)
    }
    
    
    /// Returns the next place to _save_ a boot image; the opposite of the A/B
    /// boot image last written.
    private func getNextBootABStatus() -> String {
        let configFile = getBootABStatusFile()
        let status = try! String(contentsOf: configFile)
        
        // Return the opposite of whatever was booted last.
        if (status == "A") {
            return "B"
        } else {
            return "A"
        }
    }
    
    
    /// Sets whether we're using the 'A' or 'B' boot image, for future boots.
    private func setABBootStatus(status: String) {
        assert((status == "A") || (status == "B"))
        
        let configFile = getBootABStatusFile()
        try! status.write(to: configFile, atomically: true, encoding: .utf8)
    }
    
    
    
    /// Issue a QEMU managament protocol scheme command.
    @discardableResult
    private func issueMonitorCommand(command: String) -> String {
        let terminatedCommand = "\(command)\r\n"
        
        // Send our command ...
        ensureMonitorConnection()
        try! monitorSocket?.write(from: terminatedCommand.data(using: .utf8)!)
        
        // ... and get the response.
        return try! monitorSocket!.readString()!
    }
    
    
    /// Ensures we have a connection to our VM over the QEMU management protocol.
    private func ensureMonitorConnection() {
        
        // If we already have a connection, we're done!
        if monitorSocket != nil {
            return
        }
        
        // Create a connection to QEMU via QMP.
        monitorSocket = try! Socket.create()
        try! monitorSocket!.connect(to: "127.0.0.1", port: QEMUInterface.monitorPort)
        
    }
}
