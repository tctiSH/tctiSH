//
//  ConfigServer.swift
//  Configuration server for tctiSH.
//
//  Created by Kate Temkin on 9/6/22.
//  Copyright © 2022 Kate Temkin.
//

import UIKit

/// Structure that describes a simple configuration message, as exchanged across
/// our configuration channel.
struct ConfigurationMessage: Codable {

    /// Which request this is, or answers. `tctictl` makes one up for each
    /// request, and only takes an answer with it: see `ConfigServer`.
    var id: String?

    /// The command being executed.
    var command: String

    /// The key associated with the data, if any.
    var key: String?

    /// The datum associated with the command, if any.
    var value: String?
}

/// Answers `tctictl`, which runs in the guest and talks to the app over the
/// virtio-serial port `io.ara.tctish.control`, one JSON message per line.
///
/// Each request carries an id, and its answer repeats it. The port isn't a
/// connection: anything sent while no `tctictl` has it open goes to the next
/// one to open it, which ignores answers with another id.
///
/// Requests are handled in order on a separate queue, since some wait on a
/// picker for as long as the user takes. `still_waiting` is answered at once,
/// on the main thread: a waiting `tctictl` sends it every few seconds, and
/// `unknown` tells it the request is lost, as when the guest is restored from a
/// snapshot taken while it waited.
final class ConfigServer {

    /// Who an answer is for: the id of the request it answers.
    typealias Client = String?

    /// The longest line from the guest that is kept. A bookmark, the longest
    /// thing `tctictl` sends, is a few KiB as base64.
    private static let maxMessageLength = 64 * 1024

    /// Our interface to our QEMU kernel. Should only be accessed from
    /// `handlers`, with one exception: Settings First replaces it from the main
    /// thread before the boot (`AppDelegate.releaseBootHeldForSettings`), when
    /// there is no guest yet to send anything.
    var qemu: QEMUInterface

    private let socket = ChardevSocket(path: QEMUInterface.controlSocketPath, name: "control")

    /// Where requests are handled, one at a time.
    private let handlers = DispatchQueue(label: "io.ara.tctish.configserver", qos: .userInitiated)

    /// The line arriving. Main thread.
    private var line: [UInt8] = []

    /// Whether the line arriving has run past `maxMessageLength`, and is being
    /// cut short. Main thread.
    private var lineTooLong = false

    /// The ids of the requests being handled, until they are answered. Main
    /// thread.
    private var handling: Set<String> = []

    /// Starts connecting to the control port. Main thread.
    init(qemuInterface: QEMUInterface) {
        self.qemu = qemuInterface
        socket.onReceive = { [unowned self] bytes in received(bytes) }
        socket.start()
    }

    private func received(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            guard byte != UInt8(ascii: "\n") else {
                lineArrived(Data(line), tooLong: lineTooLong)
                line.removeAll(keepingCapacity: true)
                lineTooLong = false
                continue
            }

            if line.count < Self.maxMessageLength {
                line.append(byte)
            } else {
                lineTooLong = true
            }
        }
    }

    /// Takes in one line from the guest. Main thread.
    ///
    /// `tctictl` starts each request on a new line, so a request cut off part
    /// way stays on a line by itself. A line that can't be read is answered
    /// with an error if its id can be found, so that its sender isn't left
    /// waiting.
    private func lineArrived(_ line: Data, tooLong: Bool) {
        guard !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) else {
            return
        }

        guard !tooLong,
            let message = try? JSONDecoder().decode(ConfigurationMessage.self, from: line)
        else {
            let reason = tooLong ? "the request is too long" : "the request couldn't be read"
            Log.network.warn("control: \(reason)")
            if let id = Self.leadingID(in: line) {
                sendErrorResponse(reason, to: id)
            }
            return
        }

        if message.command == "still_waiting" {
            let status = message.id.map { handling.contains($0) } == true ? "waiting" : "unknown"
            sendMessage(
                ConfigurationMessage(
                    command: "still_waiting.response", key: "status", value: status),
                to: message.id, answering: false)
            return
        }

        if let id = message.id {
            handling.insert(id)
        }
        handlers.async { [weak self] in self?.handleMessage(message) }
    }

    /// The id from the start of a request that can't be parsed. `tctictl`
    /// writes the id first.
    private static func leadingID(in line: Data) -> String? {
        let text = String(decoding: line.prefix(256), as: UTF8.self)
        guard
            let range = text.range(of: #"^\s*\{"id":"[^"\\]{1,128}""#, options: .regularExpression)
        else {
            return nil
        }
        return String(text[range].drop(while: { $0 != ":" }).dropFirst().dropFirst().dropLast())
    }

    /// Handles an incoming message from our client.
    private func handleMessage(_ message: ConfigurationMessage) {
        let client = message.id

        switch message.command {

        // Simple echo command.
        case "echo":
            let response = ConfigurationMessage(command: "response", value: message.value)
            sendMessage(response, to: client)

        // Requests that we pop up a file picker to choose a path.
        case "choose_folder":
            handleChoosePath(message: message, from: client)

        // Requests that we pop up a filer picker to choose a path, and then ensure that path is
        // accessible to QEMU.
        case "open_folder":
            handleOpenPath(message: message, from: client)

        // Requests that we share a folder for mounting. Responds with its name under /ios_host,
        // which `tctictl` bind-mounts. {"command": "prepare_mount", "key": "", "value": "/tmp"}
        case "prepare_mount":
            handlePrepareMountCommand(message: message, from: client)

        // Font configuration command.
        case "font":
            handleFontConfig(message: message, from: client)

        // Handle requests for the CWD.
        case "getcwd":
            handleGetCWD(message: message, from: client)

        // Requests that we pop up a file picker to import a pairing file, used by the JIT server to
        // reach the device.
        case "import_pairing_file":
            handleImportPairingFile(message: message, from: client)

        // Snapshots of the machine, saved, loaded, deleted and listed from inside it.
        case "snapshot_save", "snapshot_load", "snapshot_delete", "snapshot_list":
            handleSnapshot(message: message, from: client)

        // A command for QEMU's monitor, within limits; see `runMonitorCommandForGuest`.
        case "monitor":
            handleMonitor(message: message, from: client)

        // Which cache mode to mount the shared folder with.
        case "share_cache":
            handleShareCache(message: message, from: client)

        // Respond to all other commands with, basically, "idk".
        default:
            sendErrorResponse("command not recognized", to: client)
        }
    }

    /// Why the machine can't take a snapshot request right now, if it can't:
    /// it's being saved, is parked or coming back, or is changing vCPUs.
    /// Checked again under the lock; see `QEMUInterface.machineAway`.
    private func machineBusy() -> String? {
        let busy = DispatchQueue.main.sync {
            (UIApplication.shared.delegate as? AppDelegate)?.machineIsAway == true
                || Vcpus.isChanging
        }
        return busy ? "tctiSH is busy saving your session or changing vCPUs; try again" : nil
    }

    /// Saves, loads, deletes or lists snapshots for the guest.
    private func handleSnapshot(message: ConfigurationMessage, from client: Client) {
        let command = message.command

        if command == "snapshot_list" {
            respond(command, with: qemu.runMonitorCommandForGuest("info snapshots"), to: client)
            return
        }

        guard let tag = message.value else {
            sendErrorResponse("\(command) needs a snapshot's name", to: client)
            return
        }
        if let busy = machineBusy() {
            sendErrorResponse(busy, to: client)
            return
        }

        switch command {
        case "snapshot_save":
            respond(command, with: qemu.saveSnapshotForGuest(tag: tag), to: client)

        case "snapshot_load":
            let vcpus = DispatchQueue.main.sync { Vcpus.present }
            let loaded = qemu.loadSnapshotForGuest(tag: tag, vcpus: vcpus)

            // Answered either way. After a successful load, the `tctictl` that asked no longer
            // exists, so nobody reads it, but it marks the request done. If the snapshot was taken
            // by `tctictl snapshot save`, that `tctictl` is waiting again, and learns it was
            // restored from `still_waiting`, since this app has no record of its request.
            respond(command, with: loaded, to: client)
            guard case .success = loaded else { return }

            // Ask again whether Linux is up, since the snapshot may be from another boot. The
            // answer also sends the time and zone.
            DispatchQueue.main.async { GuestAgent.shared.linuxRestarting() }

        default:
            respond(command, with: qemu.deleteSnapshotForGuest(tag: tag), to: client)
        }
    }

    /// Runs a monitor command for the guest.
    private func handleMonitor(message: ConfigurationMessage, from client: Client) {
        guard let command = message.value else {
            sendErrorResponse("monitor needs a command", to: client)
            return
        }
        respond("monitor", with: qemu.runMonitorCommandForGuest(command), to: client)
    }

    /// Answers which 9p cache mode to mount the shared folder with: `mmap`,
    /// which writes back, if Write-Back Caching is on in Settings, otherwise
    /// `readahead`, which writes straight through. Write-back is safe because
    /// the guest writes out dirty data before every background save; see
    /// `GuestPreparation`.
    private func handleShareCache(message: ConfigurationMessage, from client: Client) {
        let mode = AppSetting.sharedFolderWriteBack.bool ? "mmap" : "readahead"
        sendResponse(command: "share_cache", key: "cache", value: mode, to: client)
    }

    /// Answers with what the host did, or why it didn't.
    private func respond(
        _ command: String, with result: Result<String, QEMUInterface.GuestRefusal>,
        to client: Client
    ) {
        switch result {
        case .success(let output):
            sendResponse(command: command, key: "output", value: output, to: client)
        case .failure(let refusal):
            sendErrorResponse(refusal.reason, to: client)
        }
    }

    /// Imports a pairing file chosen by the user, for JIT enablement.
    private func handleImportPairingFile(message: ConfigurationMessage, from: Client) {
        let client = from

        // No arguments; the user picks the file.
        _ = message

        switch JitPairingFile.importInteractively() {
        case .imported:
            sendResponse(
                command: "import_pairing_file", key: "path",
                value: JitPairingFile.url.path, to: client)

            // As for one imported through the app's prompt: the device is got ready, and JIT is
            // offered or switched to once it is.
            DispatchQueue.main.async { JitEnablement.pairingFileArrived() }

        case .cancelled:
            sendResponse(
                command: "import_pairing_file", key: "status",
                value: "cancelled", to: client)

        case .failed(let reason):
            // Previously reported as "cancelled", which told the user their tap had failed rather
            // than that the file couldn't be read.
            sendErrorResponse("could not import pairing file: \(reason)", to: client)
        }
    }

    /// Fetches a "folder picker" result for our client.
    private func handleChoosePath(
        message: ConfigurationMessage, from: Client, openSecurityContext: Bool = false
    ) {
        let client = from

        // No arguments, for now.
        _ = message

        // Fetch a directory from the user.
        let directory = DirectoryPicker.popUpModalDialog()

        // If we didn't get one, return that this was cancelled.
        if (directory == []) {
            sendResponse(command: "choose_folder", key: "status", value: "cancelled", to: client)
            return
        }

        // Fetch the actual URL picked; opening it, if required.
        let url = directory.first!
        if (openSecurityContext) {
            _ = url.startAccessingSecurityScopedResource()
        }

        // Return the selected URL.
        sendResponse(command: "choose_folder", key: "directory", value: url.path, to: client)
    }

    /// Fetches a "folder picker" result for our client, and returns a
    /// serialized _bookmark_ associated with a security context; so it can be
    /// used to persistently open a folder.
    private func handleOpenPath(message: ConfigurationMessage, from: Client) {
        let client = from

        // No arguments, for now.
        _ = message

        // Fetch a directory from the user.
        let directory = DirectoryPicker.popUpModalDialog()

        // If we didn't get one, return that this was cancelled.
        if (directory == []) {
            sendResponse(command: "open_folder", key: "status", value: "cancelled", to: client)
            return
        }

        // Fetch the actual URL picked; opening it, if required.
        let url = directory.first!

        // Ensure we have access to the bookmark.
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            // Get a bookmark for the relevant data...
            let bookmarkData = try url.bookmarkData()

            // ... encode it for transport ...
            let encodedBookmark = bookmarkData.base64EncodedString()

            // ... and return it to the caller.
            sendResponse(
                command: "open_folder", key: "bookmark", value: encodedBookmark, to: client)

        } catch let err {
            sendErrorResponse("failed to create bookmark: \(err)", to: client)
        }
    }

    /// Shares a folder for `tctictl` to mount, and answers with its name under
    /// `/ios_host`. The folder is a bookmark from `open_folder`, with the name
    /// to use in `key`, or a host path, with an empty `key`.
    private func handlePrepareMountCommand(message: ConfigurationMessage, from client: Client) {
        guard let value = message.value else {
            sendErrorResponse("invalid argument to a mount command", to: client)
            return
        }

        let mounted: Result<String, QEMUInterface.GuestRefusal>
        if let name = message.key, !name.isEmpty {
            // The name becomes a link in the shared folder, so it must be a single path component.
            guard Self.isShareName(name) else {
                sendErrorResponse("'\(name)' isn't a name for a shared folder", to: client)
                return
            }
            guard let bookmarkData = Data(base64Encoded: value) else {
                sendErrorResponse("invalid encoded bookmark", to: client)
                return
            }
            mounted = qemu.mount(bookmarkData: bookmarkData, predefinedTag: name)
        } else {
            mounted = qemu.mount(hostPath: value)
        }

        switch mounted {
        case .success(let tag):
            sendResponse(command: "prepare_mount", key: "tag", value: tag, to: client)
        case .failure(let refusal):
            sendErrorResponse(refusal.reason, to: client)
        }
    }

    /// Whether `name` can be a name in the shared folder: letters, digits, `.`,
    /// `_` and `-`, but not `.` or `..`.
    static func isShareName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil
            && name != "." && name != ".."
    }

    /// Command that adjusts our font size.
    private func handleFontConfig(message: ConfigurationMessage, from: Client) {
        let client = from

        // Handle each of our various parameters differently.
        switch message.key {

        // Allow adjustment of font size.
        case "size":
            if let value = message.value {
                let size = Int(value)
                if let size = size {
                    UserDefaults.standard.set(size, forKey: "font_size")
                    sendAckResponse(command: "font_size", to: client)

                } else {
                    sendErrorResponse("could not parse font size \(value)", to: client)
                }
            } else {
                sendErrorResponse("adjusting size requires an argument", to: client)
            }
        default:
            let key = message.key ?? "-nil-"
            sendErrorResponse("\(key) is not a valid font propertly", to: client)
        }

    }

    /// Command that fetches the CWD of the shell on `hvc0`, as its prompt last
    /// reported it.
    private func handleGetCWD(message: ConfigurationMessage, from: Client) {
        let client = from

        if let term = ConsoleTransport.shared.terminal {
            if let cwd = term.cwd {
                sendResponse(command: "getcwd", key: "cwd", value: cwd, to: client)
                return
            }
        }

        sendResponse(command: "getcwd", key: "unknown", value: "", to: client)
    }

    /// Indicates something was wrong with a received command.
    private func sendErrorResponse(_ message: String, to: Client) {
        sendMessage(ConfigurationMessage(command: "response", key: "error", value: message), to: to)
    }

    /// Sends a simple message across our communications channel.
    private func sendAckResponse(command: String, to: Client) {
        sendMessage(
            ConfigurationMessage(command: "\(command).response", key: "ack", value: "ok"), to: to)
    }

    /// Sends a simple message across our communications channel.
    private func sendResponse(command: String, key: String? = nil, value: String? = nil, to: Client)
    {
        sendMessage(
            ConfigurationMessage(command: "\(command).response", key: key, value: value), to: to)
    }

    /// Sends a simple message across our communications channel.
    private func sendMessage(command: String, key: String? = nil, value: String? = nil, to: Client)
    {
        sendMessage(ConfigurationMessage(command: command, key: key, value: value), to: to)
    }

    /// Sends a message to the guest, as the answer to the request `id`, or only
    /// about it, without `answering`.
    private func sendMessage(_ message: ConfigurationMessage, to id: Client, answering: Bool = true)
    {
        var message = message
        message.id = id

        guard let encoded = try? JSONEncoder().encode(message) else {
            Log.network.fail("control: couldn't encode a '\(message.command)' message")
            return
        }
        DispatchQueue.main.async { [self] in
            // Answered, so no longer waited for.
            if answering, let id {
                handling.remove(id)
            }
            socket.send(encoded + [UInt8(ascii: "\n")])
        }
    }

}
