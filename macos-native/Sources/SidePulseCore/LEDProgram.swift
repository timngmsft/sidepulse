import Foundation

public enum LEDProgram {
    public static func normalize(_ input: String) -> String {
        var output = ""
        var iterator = input.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                output.append(character); continue
            }
            switch next {
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            case "\\": output.append("\\")
            default: output.append("\\"); output.append(next)
            }
        }
        return output
    }

    public static func validate(_ program: String) throws {
        guard !program.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeError("LED program is empty.")
        }
        guard program.utf8.count <= 512 else { throw NativeError("LED programs must fit in 512 bytes.") }
        var lines = program.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count <= 20 else { throw NativeError("LED programs support at most 20 lines.") }
    }

    public static func status(_ state: DisplayState, count: Int = 8, brightness: Double = 1) -> String {
        let count = count == 2 ? 2 : 8
        let color = scaled(state.colorHex, brightness: brightness)
        switch state {
        case .idle: return "off\n\(scaled("#020204", brightness: brightness)) 6s pulse\nrepeat"
        case .done: return color
        case .ask: return "off\n\(color) 1.6s pulse\nrepeat"
        case .working:
            let delay = count == 2 ? 260 : 95
            let segments = (0..<count).map { "\($0):\(color) 760ms pulse \($0 * delay)ms" }
            return "off 160ms cosine\n" + segments.joined(separator: "; ") + "\nrepeat"
        }
    }

    public static func battery(percent: Double, charging: Bool, count: Int = 8, brightness: Double = 1) -> String {
        let count = count == 2 ? 2 : 8
        let fraction = max(0, min(1, percent / 100))
        let filled = min(count, Int(fraction * Double(count)))
        let color = scaled(percent <= 20 ? "#FF3A00" : "#00FF66", brightness: brightness)
        var lines = ["off"]
        for index in 0..<filled { lines.append("\(index):\(color)") }
        if charging && filled < count {
            lines.append("\(filled):\(color) 1.6s pulse")
            lines.append("repeat")
        }
        return lines.joined(separator: "\n")
    }

    public static func scaled(_ color: String, brightness: Double) -> String {
        let hex = String(color.dropFirst())
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return color }
        let scale = max(0, min(1, brightness.isFinite ? brightness : 0))
        let red = Int((Double((rgb >> 16) & 255) * scale).rounded())
        let green = Int((Double((rgb >> 8) & 255) * scale).rounded())
        let blue = Int((Double(rgb & 255) * scale).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    public static func write(_ program: String, to target: URL) throws {
        try validate(program)
        // The firmware watches this specific file; do not replace it via rename.
        if !FileManager.default.fileExists(atPath: target.path) {
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw NativeError("Could not create \(target.lastPathComponent).")
            }
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(program.utf8))
        try handle.synchronize()
    }
}
