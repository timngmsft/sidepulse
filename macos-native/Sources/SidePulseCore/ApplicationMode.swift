import Foundation

public enum ApplicationMode: String, Sendable {
    case standard
    case preview
    case copilotTesting = "copilot-testing"

    public var restrictsSystemChanges: Bool { self != .standard }
    public var permitsSimulation: Bool { self == .preview }
    public var permitsRemotes: Bool { self != .preview }

    public func permitsHookChanges(for provider: Provider) -> Bool {
        provider.supportsHooks && (self == .standard || (self == .copilotTesting && provider == .copilot))
    }

    public var explanation: String? {
        switch self {
        case .standard: return nil
        case .preview:
            return "Preview mode: hooks and remote connections are disabled. Use live testing mode for agent activity."
        case .copilotTesting:
            return "Live testing: Copilot hooks and Herdr remotes are enabled. Other provider hooks, hardware, power, and login changes are disabled."
        }
    }
}
