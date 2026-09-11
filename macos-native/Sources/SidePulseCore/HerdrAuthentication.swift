import Foundation

public struct HerdrAuthentication: Sendable {
    public let token: String
    public let remote: RemoteConfiguration
    public let controlPath: URL
    public let directory: URL
    public let startedAt: TimeInterval
    public var command: URL { directory.appendingPathComponent("Authenticate.command") }
    public var result: URL { directory.appendingPathComponent("result") }
    public var acknowledgement: URL { directory.appendingPathComponent("acknowledged") }
    public var accepted: URL { directory.appendingPathComponent("accepted") }
    public var cancellation: URL { directory.appendingPathComponent("cancelled") }
    public var finished: URL { directory.appendingPathComponent("finished") }

    public init(remote: RemoteConfiguration, root: URL, controlPath: URL,
                executable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) throws {
        token = UUID().uuidString
        self.remote = remote; self.controlPath = controlPath
        directory = root.appendingPathComponent("remote-auth", isDirectory: true).appendingPathComponent(token, isDirectory: true)
        startedAt = ProcessInfo.processInfo.systemUptime
        try remote.validate()
        try NativeIPC.preparePrivateDirectory(directory.deletingLastPathComponent())
        do {
            try NativeIPC.preparePrivateDirectory(directory)
            try NativeIPC.preparePrivateDirectory(controlPath.deletingLastPathComponent())
            let script = try HerdrCommands.authentication(remote: remote, controlPath: controlPath, result: result,
                                                          acknowledgement: acknowledgement, cancellation: cancellation,
                                                          accepted: accepted, finished: finished, executable: executable)
            try Data(script.utf8).write(to: command, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        } catch {
            let original = error
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { throw NativeError("\(original.localizedDescription) Cleanup also failed: \(error.localizedDescription)") }
            }
            throw original
        }
    }

    public func exitStatus() throws -> Int? {
        guard FileManager.default.fileExists(atPath: result.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 16 else {
            throw NativeError("Invalid SSH authentication result file.")
        }
        let text = try String(contentsOf: result, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status = Int(text), (0...255).contains(status) else {
            throw NativeError("Invalid SSH authentication result.")
        }
        return status
    }

    public func acknowledge() throws {
        guard !FileManager.default.fileExists(atPath: cancellation.path),
              !FileManager.default.fileExists(atPath: finished.path) else {
            throw NativeError("SSH authentication expired or was cancelled. Authenticate again.")
        }
        try Data().write(to: acknowledgement, options: .atomic)
    }
    public func cancel() throws { try Data().write(to: cancellation, options: .atomic) }
    public func removeFiles() throws { try FileManager.default.removeItem(at: directory) }
}
