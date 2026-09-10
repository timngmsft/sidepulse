import Foundation

public struct HookInstallResult {
    public var file: URL
    public var backup: URL?
}

public enum HookConfiguration {
    public static let markerStart = "# >>> sidepulse-native hooks >>>"
    public static let markerEnd = "# <<< sidepulse-native hooks <<<"

    public static func file(for provider: Provider, home: URL) -> URL {
        switch provider {
        case .codex: return home.appendingPathComponent(".codex/config.toml")
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .copilot:
            let customHome = home == FileManager.default.homeDirectoryForCurrentUser
                ? ProcessInfo.processInfo.environment["COPILOT_HOME"] : nil
            let root = customHome
                .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".copilot")
            return root.appendingPathComponent("hooks/sidepulse-native.json")
        case .grok: return home.appendingPathComponent(".grok/hooks/sidepulse-native.json")
        }
    }

    public static func command(provider: Provider, helper: URL, socket: URL, event: String? = nil) throws -> String {
        for path in [helper.path, socket.path] {
            guard path.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw NativeError("Hook paths cannot contain control characters.")
            }
        }
        var invocation = "\(shellQuote(helper.path)) --provider \(provider.rawValue) --socket \(shellQuote(socket.path))"
        if let event {
            guard events(for: provider).contains(event) else { throw NativeError("Unsupported hook event.") }
            invocation += " --event \(shellQuote(event))"
        }
        if provider == .copilot {
            // An observational hook must not deny Copilot tools if the app was moved or removed.
            invocation += " || { printf '%s\\n' 'SidePulse Native hook failed; Copilot will continue.' >&2; }"
        }
        return invocation + " # sidepulse-native"
    }

    public static func render(provider: Provider, original: String, helper: URL, socket: URL,
                              removing: Bool = false) throws -> String {
        let command = try command(provider: provider, helper: helper, socket: socket)
        if provider == .codex {
            var text = try stripManagedBlock(original)
            if removing { return text }
            text = try enableCodexHooks(text)
            guard !command.contains("'''") else { throw NativeError("This app path cannot be represented in Codex hook TOML.") }
            let entries = events(for: provider).map {
                """
                [[hooks.\($0)]]
                matcher = "*"
                [[hooks.\($0).hooks]]
                type = "command"
                command = '''\(command)'''
                """
            }.joined(separator: "\n\n")
            return text.trimmingCharacters(in: .newlines) + "\n\n" + markerStart + "\n" + entries + "\n" + markerEnd + "\n"
        }
        var root: [String: JSONValue]
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root = [:]
        } else {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(original.utf8))
            guard let object = value.object else { throw NativeError("Hook configuration must be a JSON object.") }
            root = object
        }
        if let existing = root["hooks"], existing.object == nil { throw NativeError("Existing hooks field is not an object.") }
        var hooks = root["hooks"]?.object ?? [:]
        for name in Array(hooks.keys) {
            guard let entries = hooks[name]?.array else { throw NativeError("Existing hook entries must be arrays.") }
            let remaining = entries.compactMap(removingNativeCommands)
            if remaining.isEmpty { hooks.removeValue(forKey: name) }
            else { hooks[name] = .array(remaining) }
        }
        if !removing {
            for event in events(for: provider) {
                var entries = hooks[event]?.array ?? []
                if provider == .copilot {
                    let eventCommand = try self.command(provider: provider, helper: helper, socket: socket, event: event)
                    entries.append(.object([
                        "type": .string("command"), "bash": .string(eventCommand),
                        "timeoutSec": .number(5)
                    ]))
                } else {
                    var entry: [String: JSONValue] = [
                        "hooks": .array([.object(["type": .string("command"), "command": .string(command)])])
                    ]
                    if provider != .grok || ["PreToolUse", "PostToolUse", "PostToolUseFailure",
                                             "PermissionDenied", "Notification"].contains(event) {
                        entry["matcher"] = .string("*")
                    }
                    entries.append(.object(entry))
                }
                hooks[event] = .array(entries)
            }
        }
        root["hooks"] = .object(hooks)
        if provider == .copilot { root["version"] = .number(1) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(JSONValue.object(root)), as: UTF8.self) + "\n"
    }

    public static func isInstalled(provider: Provider, home: URL) -> Bool {
        guard let text = try? String(contentsOf: file(for: provider, home: home), encoding: .utf8) else { return false }
        return provider == .codex ? text.contains(markerStart) : text.contains("# sidepulse-native")
    }

    public static func install(provider: Provider, home: URL, helper: URL, socket: URL,
                               removing: Bool = false) throws -> HookInstallResult {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw NativeError("The bundled native hook helper is missing. Build the .app bundle first.")
        }
        let file = file(for: provider, home: home)
        let destination = file.resolvingSymlinksInPath()
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if removing && !exists { return HookInstallResult(file: file, backup: nil) }
        let original = exists ? try String(contentsOf: destination, encoding: .utf8) : ""
        let rendered = try render(provider: provider, original: original, helper: helper, socket: socket, removing: removing)
        if rendered == original { return HookInstallResult(file: file, backup: nil) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = exists
            ? try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
            : nil
        var backup: URL?
        if exists {
            let parent = provider == .grok || provider == .copilot
                ? file.deletingLastPathComponent().deletingLastPathComponent() : file.deletingLastPathComponent()
            let directory = parent.appendingPathComponent("sidepulse-native-backups", isDirectory: true)
            try NativeIPC.preparePrivateDirectory(directory)
            let saved = directory.appendingPathComponent("\(file.lastPathComponent).\(UUID().uuidString).bak")
            try FileManager.default.copyItem(at: destination, to: saved)
            backup = saved
        }
        try Data(rendered.utf8).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions ?? NSNumber(value: 0o600)], ofItemAtPath: destination.path)
        return HookInstallResult(file: file, backup: backup)
    }

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func removingNativeCommands(_ entry: JSONValue) -> JSONValue? {
        if let text = entry["command"]?.string ?? entry["bash"]?.string,
           text.hasSuffix("# sidepulse-native") { return nil }
        if var object = entry.object, let children = object["hooks"]?.array {
            let remaining = children.compactMap(removingNativeCommands)
            if remaining.isEmpty { return nil }
            object["hooks"] = .array(remaining)
            return .object(object)
        }
        return entry
    }

    private static func events(for provider: Provider) -> [String] {
        switch provider {
        case .codex:
            return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                    "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop"]
        case .copilot:
            return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                    "Notification", "PreCompact", "SubagentStop", "Stop", "SessionEnd", "ErrorOccurred"]
        case .claude:
            return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                    "PermissionRequest", "Notification", "PreCompact", "PostCompact", "SubagentStop", "Stop", "SessionEnd"]
        case .grok:
            return EventNormalizer.events.filter { $0 != "PermissionRequest" && $0 != "ErrorOccurred" }
        }
    }

    private static func stripManagedBlock(_ original: String) throws -> String {
        guard let start = original.range(of: markerStart) else { return original }
        guard let end = original.range(of: markerEnd, range: start.upperBound..<original.endIndex) else {
            throw NativeError("The existing native hook block is incomplete; restore its backup before updating.")
        }
        var output = original
        output.removeSubrange(start.lowerBound..<end.upperBound)
        return output.trimmingCharacters(in: .newlines) + "\n"
    }

    private static func enableCodexHooks(_ input: String) throws -> String {
        var lines = input.components(separatedBy: "\n")
        var featuresIndex: Int?
        var sectionEnd = lines.count
        for (index, line) in lines.enumerated() {
            let plain = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if plain.range(of: #"^\[\s*(?:features|"features"|'features')\s*\]$"#, options: .regularExpression) != nil {
                featuresIndex = index; continue
            }
            if featuresIndex != nil && plain.hasPrefix("[") { sectionEnd = index; break }
            if plain.hasPrefix("features =") || plain.hasPrefix("features=") {
                throw NativeError("Codex uses an inline features table. Enable hooks there manually, then use a [features] table.")
            }
            if plain.range(of: #"^(?:"features"|'features'|features)\s*\."#, options: .regularExpression) != nil {
                throw NativeError("Codex uses dotted feature settings. Use a [features] table before installing native hooks.")
            }
        }
        if let start = featuresIndex {
            for index in (start + 1)..<sectionEnd {
                let plain = lines[index].trimmingCharacters(in: .whitespaces)
                if plain.range(of: #"^hooks\s*="#, options: .regularExpression) != nil {
                    lines[index] = "hooks = true"
                    return lines.joined(separator: "\n")
                }
            }
            lines.insert("hooks = true", at: start + 1)
            return lines.joined(separator: "\n")
        }
        return input.trimmingCharacters(in: .newlines) + "\n\n[features]\nhooks = true\n"
    }
}
