import Combine
import SidePulseCore

@MainActor
final class RemoteStatusModel: ObservableObject {
    @Published private(set) var values: [String: HerdrConnectionStatus] = [:]

    subscript(_ id: String) -> HerdrConnectionStatus? {
        get { values[id] }
        set {
            guard values[id] != newValue else { return }
            values[id] = newValue
        }
    }

    func retain(_ ids: Set<String>) {
        let next = values.filter { ids.contains($0.key) }
        if next != values { values = next }
    }
}
