//
//  QEMULauncher
//  Swift interfacing code for launching our internal QEMU.
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright ©2022 Kate Temkin. All rights reserved.
//

import Socket
import Foundation

/// Structure that stores the metadata associated with a given mount.
struct DiskMountInfo : Codable {

    /// The bookmark data assosciated with the disk mount.
    var bookmark : Data

    /// The tag used for configuring the fsdev backing file provider.
    var fsdev_tag : String

    /// The tag used for mounting the device into the VM.
    var mount_tag : String
}


/// Provides an interface for running / controlling a QEMU VM.
public class QEMUInterface {

    /// The hostfwd pattern used to make SSH connections available to the application.
    private static let sshHostForward : String = "tcp:127.0.0.1:10022-:22"

    /// The port on which we connect using the QEMU monitor.
    private static let monitorPort : Int32 = 10044

    /// Our QEMU human-readable protocol socket.
    var monitorSocket : Socket?
    var monitorSocketPath : String?

    /// A queue used for general monitor operations.
    let monitorQueue = DispatchQueue(label: "com.ktemkin.ios.tctiSH.monitor")

    /// Start our background QEMU thread.
    func startQemuThread(forceRecoveryBoot: Bool = false) {

        // Clear any state left over from previous runs.
        clearLastCWDFile()
        
        // Figure out where our QEMU resources are...
        let bundlePrefix = Bundle.main.resourcePath!
        let kernelPath = bundlePrefix + "/" + "bzImage"
        let initrdPath = bundlePrefix + "/" + "initrd.img"
        
        // ... get a disk to run with ...
        let diskPath = getPersistentStore().path
        NSLog("Disk path: \(diskPath)")
        
        // ... figure out which image we'll be restoring state from ...
        let bootImageName = getBootImageName(forceRecoveryBoot: forceRecoveryBoot)

        // ... find where our QEMU binary is actually located ...
        let qemuImage = getAppropriateQemuFramework().path

        // ... figure out the folder we'll be sharing into our environment ...
        let sharedFolder = getSharedFolder().path

        // ... get a filename for our unix domain monitor-connection socket ...
        monitorSocketPath = getDatastoreURL("monitor", fileExtension: "socket").path
        
        // ... and start up the QEMU kernel, which will start paused.
        run_background_qemu(qemuImage, kernelPath, initrdPath, bundlePrefix, diskPath, sharedFolder, bootImageName, monitorSocketPath, AppDelegate.usingJitHacks);

        // Finally, recreate our persistent mounts, so they're available in the VM.
        recreatePersistentMounts()
    }
    
    /// Saves the state of the running QEMU instance.
    /// With no arguments, updates the Instant Boot cache.
    func saveState(tag: String) {
        issueMonitorCommand("savevm \(tag)")
    }
    
    /// Saves the state of the running QEMU instance.
    /// With no arguments, loads from the Instant Boot cache.
    func loadState(tag: String) {
        issueMonitorCommand("loadvm \(tag)")
        issueMonitorCommand("c")
    }

    /// Saves the state of the running QEMU instance in a background-safe manner.
    func performBackgroundSave() {
        if let terminal = ViewController.getCurrentTerminal() {
            let nextTag = getNextInstantResumeTag()

            // Never take a snapshot before we've connected to our VM.
            if (!terminal.connected) {
                return;
            }

            saveState(tag: nextTag)
            Thread.sleep(forTimeInterval: TimeInterval(2))
            setResumeImage(tag: nextTag)
        }
    }

    /// Get the next 'instant resume' file image.
    /// This ensures we never overwrite an image until our save is complete.
    private func getNextInstantResumeTag() -> String {
        let current = getImageProperty(diskName: getDiskName(), property: "resume_image", defaultValue: "b")

        if current.last == "b" {
            return "instant_resume_a"
        } else {
            return "instant_resume_b"
        }
    }

    /// Starts or resumes the tctiSH instance's execution.
    func pause() {
        issueMonitorCommand("halt")
    }


    /// Starts or resumes the tctiSH instance's execution.
    func resume() {
        issueMonitorCommand("cont")
    }

    /// Terminates the SSH channel used for console comms.
    func stopHostChannels() {
        issueMonitorCommand("hostfwd_remove \(QEMUInterface.sshHostForward)")
    }

    /// Terminates the SSH channel used for console comms.
    func startHostChannels() {
        issueMonitorCommand("hostfwd_add \(QEMUInterface.sshHostForward)")
    }

    /// Sets up the permissions for using a bookmarked folder.
    /// Used to restore access to an iOS folder.
    private func setupMountPermissions(bookmarkData: Data) -> URL? {
        var isStale = false;

        // Rehydrate our data back into a bookmark...
        let hostPath = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
        guard (hostPath != nil) && !isStale else {
            return nil
        }

        // ... revive its security context ...
        _ = hostPath?.startAccessingSecurityScopedResource()

        return hostPath
    }

    /// Sets up a given host URL for mounting.
    func mount(bookmarkData: Data, interfaceId: String? = nil, predefinedTag: String? = nil,
               persistent: Bool = true) -> String? {
        let tag = predefinedTag ?? generateMountTag(length: 6)
        let id = interfaceId ?? generateMountTag(length: 6)

        let hostPath = setupMountPermissions(bookmarkData: bookmarkData)

        // ... and, finally, mount the target URL.
        if persistent {
            makeMountPersistent(bookmarkData: bookmarkData, interfaceId: id, tag: tag)
        }
        return mount(hostPath: hostPath!, interfaceId: id, predefinedTag: tag)
    }

    /// Saves mount data into our "VM" configuration, so we can automatically remount it on startup.
    private func makeMountPersistent(bookmarkData: Data, interfaceId: String, tag: String) {

        // Get an encapsulation of our mount data...
        let mountInfo = DiskMountInfo(bookmark: bookmarkData, fsdev_tag: interfaceId, mount_tag: tag)
        let serializedData = try! JSONEncoder().encode(mountInfo)
        let serializedString = String(data: serializedData, encoding: .utf8)!

        // ... and associate it with this image.
        let slot = getNextMountSlotName()
        setImageProperty(diskName: getDiskName(), property: slot, value: serializedString)
    }


    /// Returns the next ImageProperty name appropriate for storing a
    private func getNextMountSlotName() -> String {
        let existingSlots = getPersistentMounts().count
        return "disk_mount_\(existingSlots)"
    }

    /// Returns all known disk-mount data, so persistent disks can be remounted.
    private func getPersistentMounts() -> [DiskMountInfo] {
        var slot = 0
        var mounts : [DiskMountInfo] = []

        while true {
            let mount_info = getMountInfo(slotName: "disk_mount_\(slot)")
            if let mount_info = mount_info {
                mounts.append(mount_info)
            } else {
                return mounts
            }

            slot += 1
        }
    }

    /// Returns any mount information associated with a given disk mount slot;
    /// or nil if the slot wasn't present.
    private func getMountInfo(slotName: String, disk: String? = nil) -> DiskMountInfo? {

        // Fetch any data stored in the current mount slot.
        let diskName = disk ?? getDiskName()
        let serializedString = getImageProperty(diskName: diskName, property: slotName, defaultValue: "")
        let serializedData = Data(serializedString.utf8)

        // If there wasn't any, early abort.
        guard serializedString != "" else {
            return nil
        }

        // Finally, parse the data back into mount-info.
        return try? JSONDecoder().decode(DiskMountInfo.self, from: serializedData)
    }

    /// Re-creates a mount point on image startup.
    private func recreatePersistentMount(mount_info : DiskMountInfo) {
        _ = self.setupMountPermissions(bookmarkData: mount_info.bookmark)
    }

    /// Re-creates all mounts from the persistent mount pool.
    private func recreatePersistentMounts() {
        for mount in self.getPersistentMounts() {
            self.recreatePersistentMount(mount_info: mount)
        }
    }


    /// Sets up a given host URL for mounting.
    func mount(hostPath: URL, interfaceId: String? = nil, predefinedTag: String? = nil) -> String {
        return mount(hostPath: hostPath.path, interfaceId: interfaceId, predefinedTag: predefinedTag)
    }

    /// Sets up a given host path for mounting.
    func mount(hostPath: String, interfaceId: String? = nil, predefinedTag: String? = nil) -> String {
        let tag = predefinedTag ?? generateMountTag(length: 6)

        // Use our tag to get a unique symlink path...
        var symlinkDestination = getSharedFolder()
        symlinkDestination.appendPathComponent(tag, isDirectory: true)

        // ... and then create a symlink to the target.
        if FileManager.default.fileExists(atPath: symlinkDestination.path) {
            try? FileManager.default.removeItem(at: symlinkDestination)
        }
        try? FileManager.default.createSymbolicLink(atPath: symlinkDestination.path, withDestinationPath: hostPath)

        return tag
    }


    /// Generates a random tag suitable for use in mounting.
    private func generateMountTag(length: Int = 12) -> String {
      let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      return "m" + String((0..<length).map{ _ in letters.randomElement()! })
    }


    /// Fetches the path to the QEMU framework appropriate for this environment.
    /// Will return a JIT-capable image if JIT is supported; or a TCTI image otherwise.
    private func getAppropriateQemuFramework() -> URL {
        var frameworkURL = Bundle.main.bundleURL
        frameworkURL.appendPathComponent("Frameworks", isDirectory: true)

        // Select our QEMU binary based on whether or not we're allowed to JIT.
        var qemuName = "qemu-x86_64-softmmu"
        if (AppDelegate.usingJitHacks) {
            qemuName += "_jit"
            AppDelegate.usingJitHacks = true
        }

        frameworkURL.appendPathComponent("\(qemuName).framework", isDirectory: true)
        frameworkURL.appendPathComponent(qemuName)

        return frameworkURL
    }

    
    /// Gets the boot image used for the user-selected boot mode.
    private func getBootImageName(forceRecoveryBoot: Bool) -> String? {
        var mode = UserDefaults.standard.string(forKey: "resume_behavior")

        // If we're forcing a recovery boot, override the read mode.
        if forceRecoveryBoot {
            mode = "recovery_boot"
        }
        
        switch mode {
        case "persistent_boot":
            let resume_image = getResumeImage()
            if isFirstBoot() {
                return nil
            } else {
                return resume_image
            }
        case "snapshot_boot":
            return UserDefaults.standard.string(forKey: "boot_snapshot")
        case "recovery_boot":
            return nil
        case "clean_boot":
            return "instantboot"
        default:
            NSLog("got invalid settings from settings pane! no boot mode \(String(describing: mode))")
            exit(1);
        }
    }

    /// Returns a string indicating the currently used disc name.
    private func getDiskName() -> String {
        return UserDefaults.standard.string(forKey: "disk_name") ?? "disk"
    }
    
    /// Returns the URL to a qcow image that will acts as our persistent store.
    private func getPersistentStore() -> URL
    {
        let diskName = getDiskName()
        
        // Figure out where our persistent store would be located.
        let targetURL = getDatastoreURL(diskName, fileExtension: "qcow")

        // If it doesn't exist, create a new copy based on our empty disk.
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            let emptyDiskURL = Bundle.main.url(forResource: "empty", withExtension: "qcow")
            try! FileManager.default.copyItem(at: emptyDiskURL!, to: targetURL)

            // Reset the startup to base instant-boot, since we now have a new disk.
            setResumeImage(tag: "instantboot")
        }
    
        return targetURL
    }


    /// Returns the URL of a folder that can be used as the root of our iOS mounts.
    /// Typically mounted as `/ios_host`.
    static func getSharedFolder() -> URL
    {
        // Figure out where our persistent store would be located.
        let targetURL = getDatastoreURL("SharedFolder", fileExtension: "d")

        // If it doesn't exist, create a new copy based on our empty disk.
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            try! FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)
        }

        return targetURL
    }


    /// Returns the URL of a folder that can be used as the root of our iOS mounts.
    /// Typically mounted as `/ios_host`.
    func getSharedFolder() -> URL {
        return QEMUInterface.getSharedFolder()
    }


    /// Returns the path of a shared file that can be used to pass our last-cwd to the guest.
    /// Contents of the file are managed by our console frontend.
    static func getLastCWDFile() -> URL {
        var cwdFile = QEMUInterface.getSharedFolder()
        cwdFile.appendPathComponent("last_cwd.dat")

        return cwdFile
    }


    /// Removes any last-CWD file present, which is used to store the current CWD.
    func clearLastCWDFile() {
        let cwdFile = QEMUInterface.getLastCWDFile()

        // If we have a cwdfile, delete it.
        if FileManager.default.fileExists(atPath: cwdFile.path) {
            try? FileManager.default.removeItem(at: cwdFile)
        }
    }
    
    
    /// Retreives the path to a file in our local data store.
    /// Currently fetches a path in the per-app 'Documents' directory; but this may change.
    private static func getDatastoreURL(_ name : String, fileExtension: String, create: Bool = true) -> URL {
        
        // Figure out where our persistent store would be located.
        var targetURL = try! FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "\(name).\(fileExtension)"),
            create: create)
        
        // Scult our filename so it ends in "ab_status.conf".
        targetURL.appendPathComponent(name)
        targetURL.appendPathExtension(fileExtension)
    
        return targetURL
    }


    /// Retreives the path to a file in our local data store.
    /// Currently fetches a path in the per-app 'Documents' directory; but this may change.
    private func getDatastoreURL(_ name : String, fileExtension: String, create: Bool = true) -> URL {
        QEMUInterface.getDatastoreURL(name, fileExtension: fileExtension, create: create)
    }


    /// Returns a property from the disk-image metadata store.
    private func getImageProperty(diskName: String, property: String, defaultValue: String) -> String {
        let imageStore = UserDefaults.standard.dictionary(forKey: "images") as? [String : [String:String]]
        let images = imageStore ?? [:]
        let image = images[diskName] ?? [:]
        return image[property] ?? defaultValue
    }

    /// Sets a property from the disk-image metadata store.
    private func setImageProperty(diskName: String, property: String, value: String)  {

        // Get the current image-store...
        var imageStore = UserDefaults.standard.dictionary(forKey: "images") as? [String : [String:String]]
        var images = imageStore ?? [:]

        // ... update the relevant property value ...
        images[diskName] = images[diskName] ?? [:]
        images[diskName]![property] = value

        // ... and save it back to our configuration.
        UserDefaults.standard.set(images, forKey: "images")
    }

    /// Returns true iff this is a first-boot of the VM.
    func isFirstBoot() -> Bool {
        let image = getResumeImage()
        // FIXME: get rid of instantboot, here; it's just a simple transitionalt hing
        return (image == "") || (image == "instantboot")
    }

    /// Gets the name of the save-state to be used for resuming a VM in "persist state" mode.
    private func getResumeImage(diskName: String? = nil) -> String {
        let diskName = diskName ?? getDiskName()
        return getImageProperty(diskName: diskName, property: "resume_image", defaultValue: "")
    }

    /// Sets the name of the save-state to be used for resuming a VM in "persist state" mode.
    private func setResumeImage(tag: String, diskName: String? = nil) {
        let diskName = diskName ?? getDiskName()
        setImageProperty(diskName: diskName, property: "resume_image", value: tag)
    }

    /// Issue a QEMU managament protocol scheme command.
    private func issueMonitorCommand(_ command: String) {
        let terminatedCommand = "\(command)\r\n"
        
        // Send our command ...
        ensureMonitorConnection()
        _ = try? monitorSocket?.write(from: terminatedCommand.data(using: .utf8)!)
    }

    /// Ensures we have a connection to our VM over the QEMU management protocol.
    private func ensureMonitorConnection() {
        
        // If we already have a connection, we're done!
        if let monitorSocket = monitorSocket {
            if monitorSocket.isConnected {
                return
            }
        }
        
        // Create a connection to QEMU via QMP.
        monitorSocket = try! Socket.create(family: .unix, type: .stream, proto: .unix)
        try! monitorSocket!.connect(to: monitorSocketPath!)
    }
}
