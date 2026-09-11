import CryptoKit
import Foundation

public enum DeviceDisplay: String, Codable, CaseIterable, Identifiable {
    case agent = "Agent", battery = "Battery", custom = "Custom"
    public var id: String { rawValue }
}

public enum AwakePolicy: String, Codable, CaseIterable, Identifiable {
    case never = "Never", working = "While agents work", local = "While local agents work", always = "Always"
    public var id: String { rawValue }
}

public struct DevicePreference: Codable, Equatable {
    public var enabled = true
    public var display = DeviceDisplay.agent
    public var brightness = 0.7
    public var customProgram = "#00FF66"
    public init() {}
}

public struct RemoteConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var name = ""
    public var target = ""
    public var session = ""
    public var herdrPath = ""
    public var resolvedHerdrPath: String?
    public var enabled = true
    public init() {}
    public var displayName: String { name.isEmpty ? target : name }
    public var normalizedSession: String { session == "default" ? "" : session }
    public func sameEndpoint(as other: Self) -> Bool {
        target == other.target && normalizedSession == other.normalizedSession && herdrPath == other.herdrPath
    }
    public func normalized() -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.session = copy.normalizedSession
        copy.herdrPath = herdrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
    public func validate() throws {
        guard UUID(uuidString: id) != nil else { throw NativeError("Remote configuration has an invalid identifier.") }
        guard !target.isEmpty, !target.hasPrefix("-"),
              target.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              target.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NativeError("Enter an SSH alias or user@host, without spaces or command options.")
        }
        guard session.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || [45, 46, 95].contains($0) }) else {
            throw NativeError("Herdr session names may contain only letters, numbers, '.', '_', and '-'.")
        }
        guard herdrPath.isEmpty || (herdrPath.hasPrefix("/") &&
              herdrPath.rangeOfCharacter(from: .controlCharacters) == nil) else {
            throw NativeError("Herdr path must be an absolute remote path.")
        }
    }
}

public struct AppConfiguration: Codable, Equatable {
    public var version = 1
    public var physicalLEDsEnabled = false
    public var screenBarEnabled = false
    public var ejectPreventionEnabled = false
    public var awakePolicy = AwakePolicy.never
    public var minimumBatteryPercent = 20.0
    public var staleAfterSeconds = 3600.0
    public var doneVisibleSeconds = 1200.0
    public var devices: [String: DevicePreference] = [:]
    public var remotes: [RemoteConfiguration] = []
    public init() {}
    public func validate() throws {
        guard version == 1 else { throw NativeError("Unsupported native settings version.") }
        guard staleAfterSeconds.isFinite, staleAfterSeconds >= 30,
              doneVisibleSeconds.isFinite, doneVisibleSeconds >= 0,
              minimumBatteryPercent.isFinite, (0...100).contains(minimumBatteryPercent) else {
            throw NativeError("Invalid activity timeout or battery threshold in native settings.")
        }
        guard Set(remotes.map(\.id)).count == remotes.count else { throw NativeError("Remote identifiers must be unique.") }
        for remote in remotes { try remote.validate() }
        for device in devices.values {
            guard device.brightness.isFinite, (0...1).contains(device.brightness) else {
                throw NativeError("Device brightness must be between zero and one.")
            }
            if device.display == .custom { try LEDProgram.validate(device.customProgram) }
        }
    }
}

public struct HistoryEntry: Codable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var state: DisplayState
    public var activeCount: Int
    public var batteryPercent: Double?
    public init(date: Date, state: DisplayState, activeCount: Int, batteryPercent: Double?) {
        self.date = date; self.state = state; self.activeCount = activeCount; self.batteryPercent = batteryPercent
    }
}

public struct NativePaths {
    public let root: URL
    public let socket: URL
    public var configuration: URL { root.appendingPathComponent("settings.json") }
    public var sessions: URL { root.appendingPathComponent("sessions.json") }
    public var history: URL { root.appendingPathComponent("history.json") }
    public var log: URL { root.appendingPathComponent("application.log") }

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SidePulse Native", isDirectory: true)
        if let root {
            if root.appendingPathComponent("events.sock").path.utf8.count < 104 {
                self.socket = root.appendingPathComponent("events.sock")
            } else {
                let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
                    .prefix(8).map { String(format: "%02x", $0) }.joined()
                self.socket = URL(fileURLWithPath: "/tmp/io.sidepulse.native-\(getuid())-\(digest)/events.sock")
            }
        } else {
            self.socket = URL(fileURLWithPath: "/tmp/io.sidepulse.native-\(getuid())/events.sock")
        }
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

public enum Persistence {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONCoding.decoder().decode(type, from: Data(contentsOf: url))
    }
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONCoding.encoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
