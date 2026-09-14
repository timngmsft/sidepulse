import AppKit
import Foundation
import XCTest
@testable import SidePulseCore

final class MenuBarAlignmentTests: XCTestCase {
    func testLegacySettingsDefaultToCenterWithoutLosingOtherPreferences() throws {
        var expected = AppConfiguration()
        expected.physicalLEDsEnabled = true
        expected.screenBarEnabled = true
        expected.ejectPreventionEnabled = true
        expected.awakePolicy = .local
        expected.minimumBatteryPercent = 35
        expected.staleAfterSeconds = 900
        expected.doneVisibleSeconds = 300
        var device = DevicePreference()
        device.brightness = 0.4
        expected.devices = ["fixture": device]
        var remote = RemoteConfiguration()
        remote.target = "fixture"
        remote.resolvedHerdrPath = "/opt/herdr"
        expected.remotes = [remote]
        var object = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(expected)).object)
        object.removeValue(forKey: "menuBarAlignment")
        object.removeValue(forKey: "menuBarTextEnabled")
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(JSONValue.object(object)))
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.menuBarAlignment, .center)
        XCTAssertTrue(decoded.menuBarTextEnabled)
        try decoded.validate()
    }

    func testAllAlignmentsRoundTripAndInvalidValuesAreRejected() throws {
        for alignment in MenuBarAlignment.allCases {
            var configuration = AppConfiguration()
            configuration.menuBarAlignment = alignment
            let data = try JSONEncoder().encode(configuration)
            XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: data), configuration)
        }
        var object = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(AppConfiguration())).object)
        for invalid in [JSONValue.string("Justify"), .number(42)] {
            object["menuBarAlignment"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(JSONValue.object(object))))
        }
    }

    func testStatusTextPreferenceIsBackwardCompatibleAndPreservesAlignment() throws {
        var configuration = AppConfiguration()
        configuration.menuBarAlignment = .right
        var object = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(configuration)).object)
        object.removeValue(forKey: "menuBarTextEnabled")
        XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(JSONValue.object(object))), configuration)
        for enabled in [false, true] {
            configuration.menuBarTextEnabled = enabled
            XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration)), configuration)
        }
        for invalid in [JSONValue.string("false"), .number(0)] {
            object["menuBarTextEnabled"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(JSONValue.object(object))))
        }
    }

    func testBundledAlignmentMovesBothElementsImmediatelyAndPersists() throws {
        guard let path = ProcessInfo.processInfo.environment["SIDEPULSE_NATIVE_APP"] else {
            throw XCTSkip("Set SIDEPULSE_NATIVE_APP to exercise actual menu-bar alignment.")
        }
        let app = URL(fileURLWithPath: path)
        let root = app.deletingLastPathComponent().appendingPathComponent("alignment-\(UUID().uuidString.prefix(8))")
        let paths = NativePaths(root: root)
        try paths.prepare()
        var process: Process?
        defer {
            if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not clean up alignment fixture: \(error)") }
        }

        func request(_ object: [String: JSONValue]) throws -> JSONValue {
            let data = try NativeIPC.request(JSONEncoder().encode(JSONValue.object(object)), socket: paths.socket)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
        func action(_ name: String) throws -> JSONValue { try request(["action": .string(name)]) }
        func launch() throws {
            let child = Process()
            child.executableURL = app.appendingPathComponent("Contents/MacOS/SidePulseNative")
            child.arguments = ["--development", "--state-dir", root.path]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            process = child
            try child.run()
            let deadline = Date().addingTimeInterval(10)
            while child.isRunning && Date() < deadline {
                if (try? action("ping")["ok"]?.bool) == true { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw NativeError("The alignment fixture did not start.")
        }
        func stop() throws {
            XCTAssertEqual(try action("quit")["ok"]?.bool, true)
            let deadline = Date().addingTimeInterval(5)
            while process?.isRunning == true && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            XCTAssertFalse(process?.isRunning == true)
        }
        func setAlignment(_ alignment: MenuBarAlignment) throws {
            XCTAssertEqual(try request(["action": .string("set-menu-alignment"), "alignment": .string(alignment.rawValue)])["ok"]?.bool, true)
        }
        func setTextEnabled(_ enabled: Bool) throws {
            XCTAssertEqual(try request(["action": .string("set-menu-text"), "enabled": .bool(enabled)])["ok"]?.bool, true)
        }
        func setState(_ state: DisplayState) throws {
            XCTAssertEqual(try action("clear")["ok"]?.bool, true)
            if state == .idle { return }
            let envelope = HookEnvelope(provider: .copilot, line: .object([
                "hook_event_name": .string("Stop"), "session_id": .string("alignment-fixture"),
                "session_title": .string("Menu bar alignment"), "sidepulse_status": .string(state.rawValue),
                "last_assistant_message": .string("Fixture activity.")
            ]))
            let reply = try NativeIPC.request(JSONEncoder().encode(envelope), socket: paths.socket)
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: reply)["ok"]?.bool, true)
        }
        func assertLayout(_ alignment: MenuBarAlignment, state: DisplayState,
                          file: StaticString = #filePath, line: UInt = #line) throws {
            let snapshot = try action("snapshot")
            let ui = try XCTUnwrap(snapshot["ui"])
            let width = try XCTUnwrap(ui["width"]?.number)
            let contentWidth = try XCTUnwrap(ui["contentWidth"]?.number)
            let offset: Double
            switch alignment {
            case .left: offset = 0
            case .center: offset = (width - contentWidth) / 2
            case .right: offset = width - contentWidth
            }
            XCTAssertEqual(ui["label"]?.string, state.rawValue, file: file, line: line)
            XCTAssertEqual(ui["textEnabled"]?.bool, true, file: file, line: line)
            XCTAssertEqual(ui["alignment"]?.string, alignment.rawValue, file: file, line: line)
            XCTAssertEqual(width, 96, file: file, line: line)
            XCTAssertEqual(ui["buttonWidth"]?.number, width, file: file, line: line)
            XCTAssertEqual(ui["imageWidth"]?.number, width, file: file, line: line)
            XCTAssertEqual(ui["imageX"]?.number, 0, file: file, line: line)
            XCTAssertEqual(ui["template"]?.bool, true, file: file, line: line)
            XCTAssertEqual(try XCTUnwrap(ui["contentX"]?.number), offset, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(try XCTUnwrap(ui["stripX"]?.number), offset + 4, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(try XCTUnwrap(ui["titleX"]?.number), offset + 40, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(try XCTUnwrap(ui["titleWidth"]?.number), contentWidth - 42, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(ui["stripWidth"]?.number, 32, file: file, line: line)
            XCTAssertEqual(ui["stripHeight"]?.number, 8, file: file, line: line)
            XCTAssertEqual(ui["fontSize"]?.number, NSFont.menuBarFont(ofSize: 0).pointSize, file: file, line: line)
            XCTAssertEqual(ui["fontName"]?.string, NSFont.menuBarFont(ofSize: 0).fontName, file: file, line: line)
            try assertSegments(ui, file: file, line: line)
        }
        func assertSegments(_ ui: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(ui["segments"]?.number, 5, file: file, line: line)
            let frames = try XCTUnwrap(ui["segmentFrames"]?.array)
            XCTAssertEqual(frames.count, 5, file: file, line: line)
            for (index, frame) in frames.enumerated() {
                XCTAssertEqual(frame["x"]?.number, Double(index * 7), file: file, line: line)
                XCTAssertEqual(frame["y"]?.number, 0, file: file, line: line)
                XCTAssertEqual(frame["width"]?.number, 4, file: file, line: line)
                XCTAssertEqual(frame["height"]?.number, 8, file: file, line: line)
            }
        }
        func assertCompact(_ state: DisplayState, alignment: MenuBarAlignment,
                           file: StaticString = #filePath, line: UInt = #line) throws {
            let snapshot = try action("snapshot")
            let ui = try XCTUnwrap(snapshot["ui"])
            XCTAssertEqual(snapshot["state"]?.string, state.rawValue, file: file, line: line)
            XCTAssertEqual(ui["textEnabled"]?.bool, false, file: file, line: line)
            XCTAssertEqual(ui["label"]?.string, "", file: file, line: line)
            XCTAssertEqual(ui["titleWidth"]?.number, 0, file: file, line: line)
            XCTAssertEqual(ui["imageWidth"]?.number, 0, file: file, line: line)
            XCTAssertEqual(ui["template"]?.bool, false, file: file, line: line)
            XCTAssertEqual(ui["width"]?.number, 36, file: file, line: line)
            XCTAssertEqual(ui["buttonWidth"]?.number, 36, file: file, line: line)
            XCTAssertEqual(ui["stripX"]?.number, 2, file: file, line: line)
            XCTAssertEqual(ui["stripWidth"]?.number, 32, file: file, line: line)
            XCTAssertEqual(ui["alignment"]?.string, alignment.rawValue, file: file, line: line)
            XCTAssertEqual(ui["tooltip"]?.string, "SidePulse Native: \(state.rawValue)", file: file, line: line)
            XCTAssertEqual(ui["accessibilityLabel"]?.string, "SidePulse Native: \(state.rawValue)", file: file, line: line)
            if state == .working || state == .ask {
                XCTAssertEqual(ui["animations"]?.number, ui["reduceMotion"]?.bool == true ? 0 : 5, file: file, line: line)
            } else if state == .idle {
                XCTAssertEqual(ui["animations"]?.number, 0, file: file, line: line)
            }
            try assertSegments(ui, file: file, line: line)
        }

        try launch()
        try assertLayout(.center, state: .idle)
        for state in DisplayState.allCases {
            try setState(state)
            for alignment in MenuBarAlignment.allCases {
                try setAlignment(alignment)
                try assertLayout(alignment, state: state)
                if state == .done, let directory = ProcessInfo.processInfo.environment["SIDEPULSE_ALIGNMENT_CAPTURES"] {
                    let captured = try action("capture-status")
                    let file = try XCTUnwrap(captured["path"]?.string)
                    let destination = URL(fileURLWithPath: directory).appendingPathComponent("alignment-\(alignment.rawValue).png")
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: file), to: destination)
                }
            }
        }
        for alignment in MenuBarAlignment.allCases {
            try setAlignment(alignment)
            for state in DisplayState.allCases {
                try setState(state)
                try assertLayout(alignment, state: state)
            }
        }
        for alignment in MenuBarAlignment.allCases {
            try setAlignment(alignment)
            try setTextEnabled(false)
            for state in DisplayState.allCases {
                try setState(state)
                try assertCompact(state, alignment: alignment)
            }
            try setTextEnabled(true)
            try assertLayout(alignment, state: .done)
        }
        try setTextEnabled(false)
        for alignment in MenuBarAlignment.allCases {
            try setAlignment(alignment)
            try assertCompact(.done, alignment: alignment)
        }
        try setTextEnabled(true)
        try setState(.done)
        Thread.sleep(forTimeInterval: 0.9)
        try setAlignment(.left)
        XCTAssertEqual(try action("snapshot")["ui"]?["animations"]?.number, 0, "Alignment must not replay the completion pulse.")
        let invalid = try request(["action": .string("set-menu-alignment"), "alignment": .string("invalid")])
        XCTAssertEqual(invalid["ok"]?.bool, false)
        try assertLayout(.left, state: .done)
        XCTAssertEqual(try Persistence.load(AppConfiguration.self, from: paths.configuration)?.menuBarAlignment, .left)
        for enabled in [false, true, false] {
            try setTextEnabled(enabled)
            XCTAssertEqual(try action("snapshot")["ui"]?["animations"]?.number, 0, "Text visibility must not replay the completion pulse.")
        }
        let invalidText = try request(["action": .string("set-menu-text"), "enabled": .string("false")])
        XCTAssertEqual(invalidText["ok"]?.bool, false)
        try assertCompact(.done, alignment: .left)
        XCTAssertEqual(try Persistence.load(AppConfiguration.self, from: paths.configuration)?.menuBarTextEnabled, false)
        let capture = try action("capture-settings")
        XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(capture["path"]?.string))).count, 1000)
        if let directory = ProcessInfo.processInfo.environment["SIDEPULSE_ALIGNMENT_CAPTURES"] {
            try FileManager.default.copyItem(atPath: XCTUnwrap(capture["path"]?.string),
                                            toPath: URL(fileURLWithPath: directory).appendingPathComponent("alignment-General.png").path)
            let compact = try action("capture-status")
            try FileManager.default.copyItem(atPath: XCTUnwrap(compact["path"]?.string),
                                            toPath: URL(fileURLWithPath: directory).appendingPathComponent("compact-Done.png").path)
        }
        try stop()
        try launch()
        try assertCompact(.done, alignment: .left)
        try setTextEnabled(true)
        try assertLayout(.left, state: .done)
        try stop()
    }
}
