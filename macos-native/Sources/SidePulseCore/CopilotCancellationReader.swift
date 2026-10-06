import Darwin
import Foundation

public struct CopilotSessionSignal: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case aborted = "abort", started = "assistant.turn_start"

        var event: String { self == .aborted ? "CopilotAbort" : "CopilotTurnStart" }
    }

    public var sessionID: String
    public var file: URL
    public var kind: Kind
    public var timestamp: Date
}

public struct CopilotCancellationPoll: Sendable {
    public var signals: [CopilotSessionSignal] = []
    public var errors: [String] = []
    public var bytesRead = 0
}

// All mutable state is protected by the lock; the app polls off the main thread.
public final class CopilotCancellationReader: @unchecked Sendable {
    public static let readLimit = 262_144
    private let directory: URL
    private let lock = NSLock()
    private var cursors: [String: Cursor] = [:]
    private var failures: [String: String] = [:]

    private struct Identity: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    private struct Record: Decodable {
        var type: String
        var timestamp: JSONValue?
        var agentID: JSONValue?
        var legacyAgentID: JSONValue?

        enum CodingKeys: String, CodingKey {
            case type, timestamp, agentID = "agentId", legacyAgentID = "agent_id"
        }
    }

    private struct Cursor {
        var file: URL
        var identity: Identity?
        var offset: UInt64 = 0
        var anchor = Data()
        var pending = Data()
        var skippingLine = false
        var latest: CopilotSessionSignal?
    }

    public init(directory: URL) { self.directory = directory }

    public static func eventsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        try HookConfiguration.file(for: .copilot, home: home)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("session-state")
    }

    public static func eventFile(sessionID: String, directory: URL) throws -> URL {
        guard !sessionID.isEmpty, sessionID != ".", sessionID != "..", sessionID.utf8.count <= 255,
              !sessionID.contains("/"), !sessionID.contains("\\"),
              sessionID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NativeError("Copilot session ID cannot be used as an event-log directory.")
        }
        return directory.appendingPathComponent(sessionID, isDirectory: true).appendingPathComponent("events.jsonl")
            .standardizedFileURL
    }

    public func poll(_ sessions: [AgentSession], at now: Date? = nil) -> CopilotCancellationPoll {
        lock.lock()
        defer { lock.unlock() }
        let local = sessions.filter(\.isLocalCopilotSession)
        let retained = Set(local.map(\.id))
        cursors = cursors.filter { retained.contains($0.key) }
        failures = failures.filter { retained.contains($0.key) }
        var result = CopilotCancellationPoll()
        for session in local {
            do {
                guard let sessionID = session.sessionID else { continue }
                let fallback = try Self.eventFile(sessionID: sessionID, directory: directory)
                let file: URL
                if let path = session.copilotEventLog {
                    file = URL(fileURLWithPath: path).standardizedFileURL
                    guard path.hasPrefix("/"), file.lastPathComponent == "events.jsonl",
                          file.deletingLastPathComponent().lastPathComponent == sessionID,
                          file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "session-state" else {
                        throw NativeError("Copilot event-log path does not match its session.")
                    }
                } else { file = fallback }
                var cursor = cursors[session.id] ?? Cursor(file: file)
                if cursor.file != file { cursor = Cursor(file: file) }
                let caughtUp = try read(sessionID: sessionID, cursor: &cursor, at: now, result: &result)
                cursors[session.id] = cursor
                failures[session.id] = nil
                if caughtUp, let signal = cursor.latest {
                    let cutoff = signal.kind == .aborted ? session.copilotCancellationCutoff : session.updatedAt
                    if signal.timestamp >= cutoff { result.signals.append(signal) }
                }
            } catch {
                let message = "Copilot cancellation monitoring (\(session.referenceLabel ?? session.id)): \(error.localizedDescription)"
                if failures[session.id] != message { result.errors.append(message) }
                failures[session.id] = message
            }
        }
        return result
    }

    private func read(sessionID: String, cursor: inout Cursor, at now: Date?,
                      result: inout CopilotCancellationPoll) throws -> Bool {
        let fd = Darwin.open(cursor.file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeIPC.systemError("open the Copilot event log") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw NativeIPC.systemError("inspect the Copilot event log") }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw NativeError("Copilot event log is not a regular file.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let identity = Identity(device: info.st_dev, inode: info.st_ino)
        let size = UInt64(info.st_size)
        var reset = cursor.identity != identity || size < cursor.offset
        if !reset, !cursor.anchor.isEmpty {
            try handle.seek(toOffset: cursor.offset - UInt64(cursor.anchor.count))
            let anchor = try handle.read(upToCount: cursor.anchor.count) ?? Data()
            result.bytesRead += anchor.count
            reset = anchor != cursor.anchor
        }
        if reset {
            cursor = Cursor(file: cursor.file, identity: identity)
            cursor.offset = size > UInt64(Self.readLimit) ? size - UInt64(Self.readLimit) : 0
            if cursor.offset > 0 {
                try handle.seek(toOffset: cursor.offset - 1)
                let previous = try handle.read(upToCount: 1) ?? Data()
                result.bytesRead += previous.count
                cursor.skippingLine = previous.first != 10
            }
        }
        try handle.seek(toOffset: cursor.offset)
        let data = try handle.read(upToCount: Self.readLimit) ?? Data()
        result.bytesRead += data.count
        cursor.offset += UInt64(data.count)
        if !data.isEmpty { cursor.anchor = Data(data.suffix(64)) }
        cursor.pending.append(data)
        var lineStart = cursor.pending.startIndex
        for newline in cursor.pending.indices where cursor.pending[newline] == 10 {
            let line = cursor.pending[lineStart..<newline]
            lineStart = cursor.pending.index(after: newline)
            if cursor.skippingLine {
                cursor.skippingLine = false
                continue
            }
            if line.isEmpty { continue }
            do {
                guard line.count <= Self.readLimit else { throw NativeError("Copilot event record exceeds 256 KiB.") }
                let record = try JSONDecoder().decode(Record.self, from: line)
                guard let kind = CopilotSessionSignal.Kind(rawValue: record.type) else { continue }
                if record.agentID != nil || record.legacyAgentID != nil { continue }
                guard let timestamp = EventNormalizer.parseDate(record.timestamp),
                      timestamp.timeIntervalSince1970.isFinite, timestamp <= (now ?? Date()) else {
                    throw NativeError("Copilot session signal has an invalid or future timestamp.")
                }
                if let latest = cursor.latest, timestamp < latest.timestamp { continue }
                cursor.latest = CopilotSessionSignal(sessionID: sessionID, file: cursor.file,
                                                    kind: kind, timestamp: timestamp)
            } catch {
                cursor.latest = nil
                result.errors.append("Copilot event log (\(sessionID.prefix(8))): \(error.localizedDescription)")
            }
        }
        cursor.pending = Data(cursor.pending[lineStart...])
        if cursor.skippingLine {
            cursor.pending.removeAll(keepingCapacity: true)
        } else if cursor.pending.count > Self.readLimit {
            cursor.pending.removeAll(keepingCapacity: true)
            cursor.skippingLine = true
            cursor.latest = nil
            result.errors.append("Copilot event log (\(sessionID.prefix(8))): skipped an oversized record.")
        }
        guard fstat(fd, &info) == 0 else { throw NativeIPC.systemError("recheck the Copilot event log") }
        return info.st_size >= 0 && cursor.offset == UInt64(info.st_size)
            && cursor.pending.isEmpty && !cursor.skippingLine
    }
}
