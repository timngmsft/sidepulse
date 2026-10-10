import Foundation
import XCTest
@testable import SidePulseCore

final class PresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private var session: AgentSession {
        AgentSession(id: "remote:one", provider: .copilot, sessionID: "session-one",
                     title: "Remote work", cwd: "/remote/project", mode: .working,
                     updatedAt: now, event: "Herdr", remoteID: "host-one")
    }

    private func snapshot(_ sessions: [AgentSession]) -> MonitorSnapshot {
        MonitorSnapshot(state: .working, sessions: sessions, activeCount: sessions.count, generatedAt: now)
    }

    private var missingHooks: [Provider: Bool] {
        Dictionary(uniqueKeysWithValues: Provider.hookProviders.map { ($0, false) })
    }

    func testHookSetupRequiresAllAvailableProvidersToBeConfirmedMissing() {
        var checked: [Provider: Bool] = [:]
        for provider in Provider.hookProviders {
            XCTAssertEqual(DashboardEmptyState(mode: .standard, installedHooks: checked, hasRemotes: false), .noActivity)
            checked[provider] = false
        }
        XCTAssertEqual(DashboardEmptyState(mode: .standard, installedHooks: checked, hasRemotes: false), .hookSetup)
        checked[.copilot] = nil
        XCTAssertEqual(DashboardEmptyState(mode: .standard, installedHooks: checked, hasRemotes: false), .noActivity)
    }

    func testAnyInstalledHookSuppressesSetupWithoutRequiringOtherProviders() {
        for provider in Provider.hookProviders {
            var checked = missingHooks
            checked[provider] = true
            XCTAssertEqual(DashboardEmptyState(mode: .standard, installedHooks: checked, hasRemotes: false), .noActivity)
            XCTAssertEqual(DashboardEmptyState(mode: .standard, installedHooks: [provider: true], hasRemotes: false), .noActivity)
        }
    }

    func testConfiguredRemotesSuppressHookSetup() {
        for mode in [ApplicationMode.standard, .copilotTesting] {
            for checked in [[:], missingHooks] {
                XCTAssertEqual(DashboardEmptyState(mode: mode, installedHooks: checked, hasRemotes: true), .noActivity)
            }
        }
    }

    func testPreviewNeverOffersHookSetup() {
        for checked in [[:], missingHooks, [.copilot: true]] {
            XCTAssertEqual(DashboardEmptyState(mode: .preview, installedHooks: checked, hasRemotes: false), .noActivity)
        }
    }

    func testRestrictedModeOnlyUsesCopilotInstallationStatus() {
        var checked: [Provider: Bool] = [.codex: true, .claude: true, .grok: true]
        XCTAssertEqual(DashboardEmptyState(mode: .copilotTesting, installedHooks: checked, hasRemotes: false), .noActivity)
        checked[.copilot] = false
        XCTAssertEqual(DashboardEmptyState(mode: .copilotTesting, installedHooks: checked, hasRemotes: false), .hookSetup)
        checked[.copilot] = true
        XCTAssertEqual(DashboardEmptyState(mode: .copilotTesting, installedHooks: checked, hasRemotes: false), .noActivity)
    }

    func testHeartbeatTimesAndHeartbeatOnlyReorderingDoNotChangePresentation() {
        var second = session
        second.id = "remote:two"
        second.remoteID = "host-two"
        let before = snapshot([session, second])
        var heartbeat = session
        heartbeat.observedAt = now.addingTimeInterval(2)
        var after = snapshot([second, heartbeat])
        after.generatedAt = now.addingTimeInterval(2)

        XCTAssertTrue(after.hasSamePresentation(as: before))
        XCTAssertTrue(before.hasSamePresentation(as: after))
        XCTAssertNotEqual(after.sessions, before.sessions, "Raw freshness must remain available to monitoring.")
    }

    func testSessionContentChangesInvalidatePresentation() {
        let before = snapshot([session])
        let mutations: [(String, (inout AgentSession) -> Void)] = [
            ("identity", { $0.id = "another" }),
            ("provider", { $0.provider = .herdr }),
            ("session reference", { $0.sessionID = "session-two" }),
            ("title", { $0.title = "Renamed" }),
            ("workspace", { $0.cwd = "/remote/other" }),
            ("mode", { $0.mode = .waiting }),
            ("activity time", { $0.updatedAt = self.now.addingTimeInterval(1) }),
            ("event", { $0.event = "SessionEnd" }),
            ("message", { $0.message = "Choose an option" }),
            ("tool", { $0.tool = "shell" }),
            ("remote", { $0.remoteID = "host-two" }),
            ("remote agent", { $0.remoteAgentName = "opencode" }),
            ("terminal", { $0.remoteTerminalID = "terminal-two" }),
            ("settling deadline", { $0.postToolUseSettlesAt = self.now.addingTimeInterval(120) }),
            ("Copilot event log", { $0.copilotEventLog = "/tmp/session-state/one/events.jsonl" }),
            ("Copilot activity watermark", { $0.copilotActivityAt = self.now }),
            ("permission", { $0.pendingPermissions.insert("permission-one") }),
            ("question", { $0.pendingQuestions = ["question-one": self.now] })
        ]
        for (name, mutate) in mutations {
            var changed = session
            mutate(&changed)
            XCTAssertFalse(snapshot([changed]).hasSamePresentation(as: before), name)
        }
        XCTAssertFalse(snapshot([]).hasSamePresentation(as: before))
        var changed = before
        changed.state = .ask
        XCTAssertFalse(changed.hasSamePresentation(as: before))
        changed = before
        changed.activeCount = 0
        XCTAssertFalse(changed.hasSamePresentation(as: before))
    }

    func testFreshHeartbeatsKeepEffectiveModeWithoutRepublishingAndStillExpire() {
        let store = SessionStore()
        var live = session
        store.reconcile(remoteID: "host-one", sessions: [live])
        let presentation = store.snapshot(at: now)
        for offset in stride(from: 2, through: 60, by: 2) {
            let time = now.addingTimeInterval(Double(offset))
            live.observedAt = time
            store.reconcile(remoteID: "host-one", sessions: [live])
            let fresh = store.snapshot(at: time)
            XCTAssertTrue(fresh.hasSamePresentation(as: presentation))
            XCTAssertEqual(fresh.sessions.first?.observedAt, time)
            XCTAssertEqual(fresh.sessions.first?.mode, .working)
            XCTAssertEqual(presentation.sessions.first?.mode, .working)
        }

        let expired = store.snapshot(at: now.addingTimeInterval(76))
        XCTAssertEqual(expired.state, .idle)
        XCTAssertEqual(expired.sessions.first?.mode, .idle)
        XCTAssertFalse(expired.hasSamePresentation(as: presentation))
    }

    func testAskAndDoneAgingStillChangePresentationDespiteFreshHeartbeats() {
        for mode in [AgentMode.waiting, .blocked, .completed] {
            let store = SessionStore()
            store.staleAfter = 10
            store.doneVisible = 10
            var live = session
            live.mode = mode
            store.reconcile(remoteID: "host-one", sessions: [live])
            let before = store.snapshot(at: now)
            live.observedAt = now.addingTimeInterval(12)
            store.reconcile(remoteID: "host-one", sessions: [live])
            let after = store.snapshot(at: live.observedAt)
            XCTAssertEqual(after.state, .idle, mode.rawValue)
            XCTAssertFalse(after.hasSamePresentation(as: before), mode.rawValue)
        }
    }
}
