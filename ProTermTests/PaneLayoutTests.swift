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
