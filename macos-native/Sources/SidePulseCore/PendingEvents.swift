import Foundation

public enum PendingEvents {
    public static func directory(socket: URL) -> URL {
        socket.deletingLastPathComponent().appendingPathComponent("pending-events", isDirectory: true)
    }

    public static func enqueue(_ data: Data, socket: URL) throws {
        guard data.count <= NativeIPC.requestLimit else { throw NativeError("Hook event is too large to queue.") }
        try NativeIPC.preparePrivateDirectory(socket.deletingLastPathComponent())
        let root = directory(socket: socket)
        try NativeIPC.preparePrivateDirectory(root)
        let existing = try files(socket: socket)
        guard existing.count < 512 else { throw NativeError("The offline event queue is full; launch SidePulse Native to drain it.") }
        let file = root.appendingPathComponent("\(UUID().uuidString).json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func files(socket: URL) throws -> [URL] {
        let root = directory(socket: socket)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey],
                                                          options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted {
                let left = try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate
                let right = try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate
                return (left ?? .distantPast) < (right ?? .distantPast)
            }
    }
}
