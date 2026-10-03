import XCTest
@testable import ProTerm

/// Pane restore and close/promotion logic, with persistence redirected to a temp file.
@MainActor
final class PaneLifecycleTests: XCTestCase {
    private var file: URL!
    private var persistence: SessionPersistence!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("panes-\(UUID().uuidString).json")
        persistence = SessionPersistence(fileURL: file)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func makeManager() -> TerminalManager {
        let manager = TerminalManager(persistence: persistence)
        manager.setShellManager(ShellManager())
        return manager
    }

    private func threePaneTab(_ manager: TerminalManager) {
        XCTAssertNotNil(manager.splitActivePane(inTab: 0, axis: .horizontal))
        XCTAssertNotNil(manager.splitActivePane(inTab: 0, axis: .vertical))
    }

    func testSplitTwiceThenCloseFirstPanePromotesASurvivorAndKeepsTheTab() throws {
        let manager = makeManager()
        let original = manager.sessions[0]
        manager.updateTabName(for: original.id, name: "Work")
        manager.updateTabColor(for: original.id, color: .blue)
        threePaneTab(manager)
        XCTAssertEqual(manager.paneLayouts[original.id]?.leafIDs.count, 3)

        manager.setActivePane(original.id)
        XCTAssertTrue(manager.closeActivePane(inTab: 0))

        XCTAssertEqual(manager.sessions.count, 1, "the tab must survive")
        let promoted = manager.sessions[0]
        XCTAssertNotEqual(promoted.id, original.id)
        XCTAssertNil(manager.paneLayouts[original.id], "old key must be gone")
        XCTAssertEqual(manager.paneLayouts[promoted.id]?.leafIDs.count, 2)
        XCTAssertTrue(manager.paneLayouts[promoted.id]?.contains(promoted.id) == true)
        XCTAssertEqual(manager.getTabMetadata(for: promoted.id).name, "Work")
        XCTAssertEqual(manager.getTabMetadata(for: promoted.id).color, .blue)
        XCTAssertEqual(manager.activeSession(at: 0).id, promoted.id)
        XCTAssertTrue(manager.isActivePane(promoted.id))
        XCTAssertNil(manager.session(forPane: original.id), "the closed session is gone")
        // The surviving other pane is still resolvable (reconcile must not have torn it down).
        let others = manager.paneLayouts[promoted.id]!.leafIDs.filter { $0 != promoted.id }
        XCTAssertEqual(others.count, 1)
        XCTAssertNotNil(manager.session(forPane: others[0]))
        XCTAssertFalse(manager.isActivePane(others[0]))
    }

    func testClosingDownToOnePaneRemovesTheLayoutAndFurtherCloseIsRejected() {
        let manager = makeManager()
        threePaneTab(manager)
        manager.setActivePane(manager.sessions[0].id)
        XCTAssertTrue(manager.closeActivePane(inTab: 0))   // 3 -> 2 (promotes)
        XCTAssertTrue(manager.closeActivePane(inTab: 0))   // 2 -> 1 (promotes again)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(manager.paneLayouts.isEmpty, "a single pane is a plain tab")
        XCTAssertTrue(manager.activePane.isEmpty)
        XCTAssertFalse(manager.closeActivePane(inTab: 0), "nothing to close on an unsplit tab")
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testClosingANonFirstPaneKeepsTheTabSession() {
        let manager = makeManager()
        let tab = manager.sessions[0]
        let second = manager.splitActivePane(inTab: 0, axis: .horizontal)!
        XCTAssertEqual(manager.activeSession(at: 0).id, second.id)
        XCTAssertTrue(manager.closeActivePane(inTab: 0))
        XCTAssertEqual(manager.sessions[0].id, tab.id)
        XCTAssertTrue(manager.paneLayouts.isEmpty)
    }

    func testSavedSplitLayoutIsRestoredWithRatiosAndActivePane() throws {
        let saved = SessionSnapshot(
            id: UUID(), title: "Restored", scrollPosition: 0, cwd: NSHomeDirectory(), color: "Green",
            panes: .split(vertical: false, ratio: 0.3,
                          first: .leaf(cwd: NSHomeDirectory(), primary: true),
                          second: .split(vertical: true, ratio: 0.6,
                                         first: .leaf(cwd: "/definitely/not/here", primary: false),
                                         second: .leaf(cwd: nil, primary: false))),
            activePaneIndex: 1)
        persistence.save(snapshots: [saved])

        let manager = makeManager()
        let tab = manager.sessions[0]
        XCTAssertEqual(manager.getTabMetadata(for: tab.id).name, "Restored")
        let layout = try XCTUnwrap(manager.paneLayouts[tab.id])
        XCTAssertEqual(layout.leafIDs.count, 3)
        XCTAssertEqual(layout.leafIDs.first, tab.id, "the tab's own session is the first leaf")
        XCTAssertEqual(Set(manager.paneRatios.values), [0.3, 0.6])
        XCTAssertEqual(manager.activeSession(at: 0).id, layout.leafIDs[1])
        for id in layout.leafIDs { XCTAssertNotNil(manager.session(forPane: id)) }
        XCTAssertEqual(manager.session(forPane: layout.leafIDs[1])?.cwd.path, NSHomeDirectory(),
                       "a missing folder falls back to home")
    }

    func testCorruptSavedLayoutIsIgnored() {
        let corrupt = SessionSnapshot(
            id: UUID(), title: "Bad", scrollPosition: 0, cwd: nil, color: nil,
            panes: .split(vertical: true, ratio: 0.5, first: .leaf(cwd: nil, primary: false),
                          second: .leaf(cwd: nil, primary: false)),
            activePaneIndex: 0)
        persistence.save(snapshots: [corrupt])
        let manager = makeManager()
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(manager.paneLayouts.isEmpty)
    }

    func testSnapshotAfterPromotionIsValidAndRoundTrips() throws {
        let manager = makeManager()
        threePaneTab(manager)
        manager.setActivePane(manager.sessions[0].id)
        XCTAssertTrue(manager.closeActivePane(inTab: 0))

        let snapshots = persistence.load()
        XCTAssertEqual(snapshots.count, 1)
        let panes = try XCTUnwrap(snapshots[0].panes)
        XCTAssertTrue(panes.isValid(maxPanes: TerminalManager.maxPanesPerTab))
        XCTAssertEqual(panes.leafCount, 2)

        // A second manager restores exactly that shape.
        let restored = makeManager()
        XCTAssertEqual(restored.paneLayouts[restored.sessions[0].id]?.leafIDs.count, 2)
    }
}
