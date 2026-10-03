import XCTest
@testable import ProTerm

@MainActor
final class PluginManagerTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        suite = "proterm.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private func manifestJSON(id: String = "p.one", commands: String = #"[{"title":"Hi","command":"echo hi"}]"#) -> Data {
        Data(#"{"id":"\#(id)","name":"One","version":"1.0","commands":\#(commands)}"#.utf8)
    }

    private func writePlugin(folder: String, data: Data) throws {
        let url = dir.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try data.write(to: url.appendingPathComponent("plugin.json"))
    }

    // MARK: manifest

    func testValidManifestDecodes() throws {
        let manifest = try PluginManifest.decode(manifestJSON())
        XCTAssertEqual(manifest.commands.map(\.title), ["Hi"])
    }

    func testInvalidManifestsAreRejected() {
        let cases: [(Data, String)] = [
            (manifestJSON(id: "bad id!"), "id"),
            (manifestJSON(commands: "[]"), "at least one command"),
            (manifestJSON(commands: #"[{"title":"A","command":"x"},{"title":"A","command":"y"}]"#), "duplicate"),
            (manifestJSON(commands: #"[{"title":"A","command":"  "}]"#), "empty"),
            (manifestJSON(commands: #"[{"title":"A","command":"x {{p}}","inputs":[{"name":"1bad"}]}]"#), "not allowed"),
            (manifestJSON(commands: #"[{"title":"A","command":"x","inputs":[{"name":"pluginDir"}]}]"#), "not allowed"),
            (Data("{".utf8), "not valid")
        ]
        for (data, fragment) in cases {
            XCTAssertThrowsError(try PluginManifest.decode(data), fragment) { error in
                XCTAssertTrue(error.localizedDescription.contains(fragment), "\(error.localizedDescription) should mention \(fragment)")
            }
        }
    }

    // MARK: expansion

    func testExpansionQuotesValuesAndRejectsUndeclaredTokens() {
        XCTAssertEqual(PluginCommandBuilder.expand("git checkout {{b}}", values: ["b": "main"]), "git checkout 'main'")
        XCTAssertEqual(PluginCommandBuilder.expand("echo {{ b }} {{b}}", values: ["b": "x"]), "echo 'x' 'x'")
        XCTAssertNil(PluginCommandBuilder.expand("echo {{missing}}", values: [:]))
        XCTAssertEqual(PluginCommandBuilder.expand("no tokens", values: [:]), "no tokens")
        XCTAssertEqual(PluginCommandBuilder.expand("broken {{", values: [:]), "broken {{")
    }

    func testQuotedInputCannotInjectCommands() throws {
        let evil = "a'; echo INJECTED; echo '"
        let line = try XCTUnwrap(PluginCommandBuilder.expand("printf %s {{x}}", values: ["x": evil]))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(output, evil, "input must be passed through as one literal argument")
    }

    // MARK: manager

    func testScanFindsValidPluginsAndReportsBadOnes() throws {
        try writePlugin(folder: "good", data: manifestJSON())
        try writePlugin(folder: "broken", data: Data("nope".utf8))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let manager = PluginManager(directory: dir, defaults: defaults)
        XCTAssertEqual(manager.plugins.map(\.id), ["p.one"])
        XCTAssertEqual(Set(manager.failures.map(\.folder)), ["broken", "empty"])
        XCTAssertFalse(manager.plugins[0].isEnabled, "plugins start disabled")
    }

    func testEnablingPersistsAndEditingManifestRevokesApproval() throws {
        try writePlugin(folder: "good", data: manifestJSON())
        var manager = PluginManager(directory: dir, defaults: defaults)
        manager.setEnabled(true, pluginID: "p.one")
        XCTAssertEqual(manager.enabledCommands.count, 1)

        manager = PluginManager(directory: dir, defaults: defaults)  // relaunch
        XCTAssertTrue(manager.plugins[0].isEnabled)

        try writePlugin(folder: "good", data: manifestJSON(commands: #"[{"title":"Hi","command":"rm -rf ~"}]"#))
        manager.reload()
        XCTAssertFalse(manager.plugins[0].isEnabled)
        XCTAssertTrue(manager.plugins[0].needsReapproval)
        XCTAssertTrue(manager.enabledCommands.isEmpty)
    }

    func testInstallRejectsDuplicatesAndRemoveStaysInsideDirectory() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try manifestJSON().write(to: source.appendingPathComponent("plugin.json"))

        let manager = PluginManager(directory: dir, defaults: defaults)
        XCTAssertEqual(try manager.install(from: source), "p.one")
        XCTAssertEqual(manager.plugins.count, 1)
        XCTAssertThrowsError(try manager.install(from: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "install copies, never moves")

        try manager.remove(pluginID: "p.one")
        XCTAssertTrue(manager.plugins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("p.one").path))
    }

    func testExamplePluginIsValid() throws {
        let manager = PluginManager(directory: dir, defaults: defaults)
        try manager.writeExamplePlugin()
        XCTAssertEqual(manager.plugins.map(\.id), ["proterm.example"])
        XCTAssertTrue(manager.failures.isEmpty)
    }
}
