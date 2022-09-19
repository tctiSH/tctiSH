//
//  ConfigServer.swift
//  Configuration server for tctiSH.
//
//  Created by Kate Temkin on 9/6/22.
//  Copyright © 2022 Kate Temkin.
//

import Atomics
import Foundation
import Socket

/// Structure that describes a simple configuration message,
/// as exchanged across our configuration channel.
struct ConfigurationMessage : Codable {

    /// The command being executed.
    var command : String

    /// The key associated with the data, if any.
    var key : String?

    /// The datum associated with the command, if any.
    var value : String?
}


/// Small server that provides a configuration backend to the tctiSH client.
class ConfigServer {
    typealias Client = Socket

    /// The port on which we listen for configuration messages.
    private static let configurationPort : Int = 10050

    /// Maximum length we'll allow in a message payload.
    private static let maxMessageLength = 4096

    /// The sockets on which we'll receive commands from the tctiSH instance.
    var connectedClients = [Int32: Socket]()

    /// A queue used to synchronize access to our sockets.
    let clientLockQueue = DispatchQueue(label: "com.ktemkin.ios.tctiSH.configserver")

    /// Our interface to our QEMU kernel.
    /// Should only be accessed from our command loop.
    private var qemu : QEMUInterface

    /// The thread that's running our command-loop.
    private var thread : Thread?

    /// Flag that's used to indicate when we should stop.
    private var stopping : ManagedAtomic<Bool>

    /// Brings up a server and starts it listening.
    init(qemuInterface: QEMUInterface, listenImmediately: Bool = false) {
        self.qemu = qemuInterface
        self.stopping = ManagedAtomic<Bool>(false)

        if (listenImmediately) {
            listen()
        }
    }

    /// Starts a thread that listens and handles any requests from our client.
    func listen() {
        let queue = DispatchQueue.global(qos: .userInteractive)
        queue.async { [unowned self] in

            // Wait for a new connection from our guest...
            let socket = try! Socket.create()
            try! socket.listen(on: ConfigServer.configurationPort)

            // Try to get a new connection.
            while !self.stopping.load(ordering: .relaxed) {
                do {
                    let newClient = try socket.acceptClientConnection()
                    self.handleClient(client: newClient)
                } catch {}
            }
        }
    }

    /// Handles any communications with a connected client.
    private func handleClient(client: Socket) {
        var clientAlive = true
        var buffer = Data(capacity: ConfigServer.maxMessageLength)

        // TODO: possibly bump this up from background?
        let queue = DispatchQueue.global(qos: .background)

        // Mark the new socket as connected...
        clientLockQueue.sync { [unowned self, client] in
            self.connectedClients[client.socketfd] = client
        }

        // ... and handle requests from it.
        queue.async { [unowned self, client] in

            // ... and then go into a simple command loop.
            do {
                while clientAlive {

                    // Get the data that was captured.
                    let length = try client.read(into: &buffer)

                    // If we didn't get any data, the other side has closed the connection.
                    // This communication is complete.
                    if length == 0 {
                        clientAlive = false
                    }
                    // Otherwise, process the client request.
                    else {
                        self.handleMessage(rawMessage: buffer, from: client)
                    }
                }
            } catch {
                // On any error, disconnect our socket.
                clientAlive = false
            }

            // Now that we're disconnected, we can erase our knowledge of this client.
            self.clientLockQueue.sync { [unowned self, client] in
                self.connectedClients[client.socketfd] = nil
            }
        }
    }


    /// Handles an incoming message from our client.
    private func handleMessage(rawMessage: Data, from: Client) {
        let client = from

        do {
            let message = try JSONDecoder().decode(ConfigurationMessage.self, from: rawMessage)

            switch message.command {

            // Simple echo command.
            case "echo":
                let response = ConfigurationMessage(command: "response", value: message.value)
                sendMessage(response, to: client)

            // Requests that we pop up a file picker to choose a path.
            case "choose_folder":
                handleChoosePath(message: message, from: client)

            // Requests that we pop up a filer picker to choose a path,
            // and then ensure that path is accessible to QEMU.
            case "open_folder":
                handleOpenPath(message: message, from: client)

            // Requests that we prepare a given device for mounting.
            // Responds with the 'tag' used to mount the device with a `mount -t 9p` command.
            // {"command": "prepare_mount", "value": "/tmp"}
            case "prepare_mount":
                handlePrepareMountCommand(message: message, from: client)

            // Font configuration command.
            case "font":
                handleFontConfig(message: message, from: client)

            // Respond to all other commands with, basically, "idk".
            default:
                sendErrorResponse("command not recognized", to: client)
            }

        } catch let err {
            sendErrorResponse("error processing command: \(err)", to: client)
        }
    }

    /// Fetches a "folder picker" result for our client.
    private func handleChoosePath(message: ConfigurationMessage, from: Client, openSecurityContext: Bool = false) {
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

    /// Fetches a "folder picker" result for our client, and returns a serialized _bookmark_
    /// associated with a security context; so it can be used to persistently open a folder.
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
            sendResponse(command: "open_folder", key: "bookmark", value: encodedBookmark, to: client)

        } catch let err {
            sendErrorResponse("failed to create bookmark: \(err)", to: client)
        }
    }


    /// Command that sets up the QEMU side of a host-side mount.
    private func handlePrepareMountCommand(message: ConfigurationMessage, from: Client) {
        let client = from

        if let hostPath = message.value {
            var tag = ""
            var isBookmark = false

            // If we have a type, check to see if this is actually an encoded bookmark.
            if let type = message.key {
                isBookmark = (type != "")
            }

            // If we have a bookmark, decode it to a URL, and then use that to mount.
            if isBookmark {
                // Rehydrate the bookmark back into a URL...
                let bookmarkData = Data(base64Encoded: hostPath)
                if let bookmarkData = bookmarkData {

                    // ... and use it to re-mount the image.
                    let mount_result = qemu.mount(bookmarkData: bookmarkData, predefinedTag: message.key!)
                    if let mount_result = mount_result {
                        tag = mount_result
                    } else {
                        sendErrorResponse("bookmark no longer valid", to: client)
                    }

                } else {
                    sendErrorResponse("invalid encoded bookmark", to: client)
                }

            }
            // Otherwise, use the host path directly.
            else {
                tag = qemu.mount(hostPath: hostPath)
            }

            // ... and send the generated tag back to the host.
            let response = ConfigurationMessage(command: "prepare_mount.response", key: "tag", value: tag)
            sendMessage(response, to: client)
        } else {
            sendErrorResponse("invalid argument to a mount command", to: client)
        }

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

    /// Indicates something was wrong with a received command.
    private func sendErrorResponse(_ message: String, to: Client) {
        sendMessage(ConfigurationMessage(command: "response", key: "error", value: message), to: to)
    }

    /// Sends a simple message across our communications channel.
    private func sendAckResponse(command: String,to: Client) {
        sendMessage(ConfigurationMessage(command: "\(command).response", key: "ack", value: "ok"), to: to)
    }

    /// Sends a simple message across our communications channel.
    private func sendResponse(command: String, key: String? = nil, value: String? = nil, to: Client) {
        sendMessage(ConfigurationMessage(command: "\(command).response", key: key, value: value), to: to)
    }

    /// Sends a simple message across our communications channel.
    private func sendMessage(command: String, key: String? = nil, value: String? = nil, to: Client) {
        sendMessage(ConfigurationMessage(command: command, key: key, value: value), to: to)
    }

    /// Sends a simple message across our communications channel.
    private func sendMessage(_ message: ConfigurationMessage, to: Client) {
        do {
            let rawMessage = try JSONEncoder().encode(message)
            try to.write(from: rawMessage)
            try to.write(from: "\n")
        } catch {
            NSLog("failed to send message!")
        }
    }

}
