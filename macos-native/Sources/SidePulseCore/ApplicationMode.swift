import Foundation

public enum ApplicationMode: String, Sendable {
    case standard
    case preview
    case copilotTesting = "copilot-testing"

    public var restrictsSystemChanges: Bool { self != .standard }
    public var permitsSimulation: Bool { self == .preview }
    public var permitsRemotes: Bool { self != .copilotTesting }

    public func permitsHookChanges(for provider: Provider) -> Bool {
        self == .standard || (self == .copilotTesting && provider == .copilot)
    }

    public var explanation: String? {
        switch self {
        case .standard: return nil
        case .preview:
            return "Preview mode: hook installation is disabled. Use Copilot testing mode for live agent activity."
        case .copilotTesting:
            return "Copilot live testing: only Copilot hooks can be changed. Other integrations, hardware, power, and login changes are disabled."
        }
    }
}
