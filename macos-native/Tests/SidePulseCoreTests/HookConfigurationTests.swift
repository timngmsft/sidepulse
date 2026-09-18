import Foundation
import XCTest
@testable import SidePulseCore

final class HookConfigurationTests: XCTestCase {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent("spn-hooks-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, for provider: Provider) throws {
        let file = try HookConfiguration.file(for: provider, home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func testDetectsMissingInstalledAndRemovedHooksForEveryProvider() throws {
        let helper = URL(fileURLWithPath: "/usr/bin/true")
        let socket = home.appendingPathComponent("events.sock")
        for provider in Provider.hookProviders {
            XCTAssertFalse(try HookConfiguration.isInstalled(provider: provider, home: home), provider.rawValue)
            try write("\n ", for: provider)
            XCTAssertFalse(try HookConfiguration.isInstalled(provider: provider, home: home), provider.rawValue)
            _ = try HookConfiguration.install(provider: provider, home: home, helper: helper, socket: socket)
            XCTAssertTrue(try HookConfiguration.isInstalled(provider: provider, home: home), provider.rawValue)
            _ = try HookConfiguration.install(provider: provider, home: home, helper: helper, socket: socket, removing: true)
            XCTAssertFalse(try HookConfiguration.isInstalled(provider: provider, home: home), provider.rawValue)
        }
    }

    func testMarkersOutsideJSONHookCommandsAreNotAnInstallation() throws {
        let configurations = [
            ##"{"note":"# sidepulse-native"}"##,
            ##"{"hooks":{"Stop":[{"matcher":"# sidepulse-native","hooks":[]}]}}"##,
            ##"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo unrelated"}]}]}}"##,
            ##"{"hooks":{"Stop":[{"type":"command","bash":"echo legacy # sidepulse"}]}}"##
        ]
        for provider in Provider.hookProviders where provider != .codex {
            for text in configurations {
                try write(text, for: provider)
                XCTAssertFalse(try HookConfiguration.isInstalled(provider: provider, home: home), "\(provider): \(text)")
            }
        }
    }

    func testMalformedJSONConfigurationsAreUnknownRatherThanMissing() throws {
        let configurations = [
            ##"{"hooks":"# sidepulse-native""##,
            "[]",
            ##"{"hooks":[]}"##,
            ##"{"hooks":{"Stop":"# sidepulse-native"}}"##,
            ##"{"hooks":{"Stop":["# sidepulse-native"]}}"##,
            ##"{"hooks":{"Stop":[{"hooks":"# sidepulse-native"}]}}"##,
            ##"{"hooks":{"Stop":[{"bash":"true # sidepulse-native"},false]}}"##,
            ##"{"hooks":{"Stop":[{"hooks":[{"command":"true # sidepulse-native"},null]}]}}"##,
            ##"{"hooks":{"Stop":[{"bash":"true # sidepulse-native"}],"PreToolUse":false}}"##
        ]
        for provider in Provider.hookProviders where provider != .codex {
            for text in configurations {
                try write(text, for: provider)
                XCTAssertThrowsError(try HookConfiguration.isInstalled(provider: provider, home: home), "\(provider): \(text)")
            }
        }
    }

    func testReadAndEncodingFailuresAreUnknownRatherThanMissing() throws {
        for provider in Provider.hookProviders {
            try write("", for: provider)
            let file = try HookConfiguration.file(for: provider, home: home)
            try Data([0xff, 0xfe, 0xff]).write(to: file)
            XCTAssertThrowsError(try HookConfiguration.isInstalled(provider: provider, home: home), provider.rawValue)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            XCTAssertThrowsError(try HookConfiguration.isInstalled(provider: provider, home: home), provider.rawValue)
        }
    }

    func testIncompleteCodexBlockIsUnknownRatherThanInstalled() throws {
        try write("\(HookConfiguration.markerStart)\ncommand = 'native # sidepulse-native'\n", for: .codex)
        XCTAssertThrowsError(try HookConfiguration.isInstalled(provider: .codex, home: home))
    }

    func testCodexRequiresANativeCommandInsideItsManagedBlock() throws {
        try write("note = '# sidepulse-native'\n\(HookConfiguration.markerStart)\n\(HookConfiguration.markerEnd)\n", for: .codex)
        XCTAssertFalse(try HookConfiguration.isInstalled(provider: .codex, home: home))
    }

    func testRemoteProvidersDoNotHaveLocalHookInstallationStatus() {
        XCTAssertThrowsError(try HookConfiguration.isInstalled(provider: .herdr, home: home))
    }
}
