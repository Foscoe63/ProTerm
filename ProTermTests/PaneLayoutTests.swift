import XCTest
@testable import ProTerm

final class PaneLayoutTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testSplittingReplacesLeafAndKeepsReadingOrder() {
        let tree = PaneNode.leaf(a).splitting(leaf: a, axis: .horizontal, newLeaf: b)
        XCTAssertEqual(tree.leafIDs, [a, b])
        let nested = tree.splitting(leaf: b, axis: .vertical, newLeaf: c)
        XCTAssertEqual(nested.leafIDs, [a, b, c])
        if case .split(_, let axis, _, let second) = nested {
            XCTAssertEqual(axis, .horizontal)
            if case .split(_, let innerAxis, _, _) = second { XCTAssertEqual(innerAxis, .vertical) } else { XCTFail() }
        } else { XCTFail() }
    }

    func testSplittingUnknownLeafIsNoOp() {
        let tree = PaneNode.leaf(a)
        XCTAssertEqual(tree.splitting(leaf: b, axis: .horizontal, newLeaf: c), tree)
    }

    func testRemovingPromotesSiblingAndCollapsesToLeaf() {
        let tree = PaneNode.leaf(a).splitting(leaf: a, axis: .horizontal, newLeaf: b)
            .splitting(leaf: b, axis: .vertical, newLeaf: c)
        XCTAssertEqual(tree.removing(leaf: c)?.leafIDs, [a, b])
        XCTAssertEqual(tree.removing(leaf: a)?.leafIDs, [b, c])
        XCTAssertEqual(PaneNode.leaf(a).splitting(leaf: a, axis: .vertical, newLeaf: b).removing(leaf: b), .leaf(a))
        XCTAssertNil(PaneNode.leaf(a).removing(leaf: a))
    }
}

final class PaneSnapshotTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    private func sampleTree() -> (PaneNode, UUID) {
        let tree = PaneNode.leaf(a).splitting(leaf: a, axis: .horizontal, newLeaf: b)
            .splitting(leaf: b, axis: .vertical, newLeaf: c)
        guard case .split(let outer, _, _, _) = tree else { fatalError() }
        return (tree, outer)
    }

    func testSnapshotCapturesShapeCwdAndRatio() {
        let (tree, outer) = sampleTree()
        let snap = tree.snapshot(
            primary: a, cwd: { $0 == self.a ? "/tmp" : nil }, ratio: { $0 == outer ? 0.3 : 0.5 })
        guard case .split(let vertical, let ratio, let first, let second) = snap else { return XCTFail() }
        XCTAssertFalse(vertical)
        XCTAssertEqual(ratio, 0.3)
        XCTAssertEqual(first, .leaf(cwd: "/tmp", primary: true))
        guard case .split(let innerVertical, _, _, _) = second else { return XCTFail() }
        XCTAssertTrue(innerVertical)
        XCTAssertEqual(snap.leafCount, 3)
        XCTAssertTrue(snap.isValid(maxPanes: 6))
    }

    func testCodableRoundTrip() throws {
        let (tree, _) = sampleTree()
        let snap = tree.snapshot(primary: a, cwd: { _ in "/Users/x/My Folder" }, ratio: { _ in 0.4 })
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(decoded, snap)
    }

    func testValidationRejectsCorruptSnapshots() {
        let two = PaneSnapshot.split(vertical: false, ratio: 0.5,
                                     first: .leaf(cwd: nil, primary: true), second: .leaf(cwd: nil, primary: false))
        XCTAssertTrue(two.isValid(maxPanes: 6))
        XCTAssertFalse(two.isValid(maxPanes: 1), "over the pane limit")
        XCTAssertFalse(PaneSnapshot.leaf(cwd: nil, primary: true).isValid(maxPanes: 6), "a single pane is not a split")
        let noPrimary = PaneSnapshot.split(vertical: true, ratio: 0.5,
                                           first: .leaf(cwd: nil, primary: false), second: .leaf(cwd: nil, primary: false))
        XCTAssertFalse(noPrimary.isValid(maxPanes: 6))
        let twoPrimary = PaneSnapshot.split(vertical: true, ratio: 0.5,
                                            first: .leaf(cwd: nil, primary: true), second: .leaf(cwd: nil, primary: true))
        XCTAssertFalse(twoPrimary.isValid(maxPanes: 6))
    }

    func testOldSessionFilesWithoutPanesStillDecode() throws {
        let json = #"[{"id":"D2C3F05E-1E9D-4D5C-B196-6D550957A87B","title":"Session A06E","scrollPosition":0}]"#
        let decoded = try JSONDecoder().decode([SessionSnapshot].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].panes)
        XCTAssertNil(decoded[0].activePaneIndex)
    }
}
