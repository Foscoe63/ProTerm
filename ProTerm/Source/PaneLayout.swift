import Foundation

enum PaneAxis: Equatable {
    case horizontal  // panes side by side
    case vertical    // panes stacked
}

/// Binary split tree for a tab. Leaves hold session IDs; the tab's own session is always one of them.
indirect enum PaneNode: Equatable {
    case leaf(UUID)
    case split(id: UUID, axis: PaneAxis, first: PaneNode, second: PaneNode)

    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let first, let second): return first.leafIDs + second.leafIDs
        }
    }

    var splitIDs: [UUID] {
        switch self {
        case .leaf: return []
        case .split(let id, _, let first, let second): return [id] + first.splitIDs + second.splitIDs
        }
    }

    func contains(_ sessionID: UUID) -> Bool { leafIDs.contains(sessionID) }

    /// Replaces `leaf` with a split of that leaf and `newLeaf` (new pane second).
    func splitting(leaf target: UUID, axis: PaneAxis, newLeaf: UUID) -> PaneNode {
        switch self {
        case .leaf(let id) where id == target:
            return .split(id: UUID(), axis: axis, first: .leaf(id), second: .leaf(newLeaf))
        case .leaf:
            return self
        case .split(let id, let splitAxis, let first, let second):
            return .split(
                id: id, axis: splitAxis,
                first: first.splitting(leaf: target, axis: axis, newLeaf: newLeaf),
                second: second.splitting(leaf: target, axis: axis, newLeaf: newLeaf))
        }
    }

    /// Removes a leaf; its sibling takes the parent's place. Returns nil if nothing is left.
    func removing(leaf target: UUID) -> PaneNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let id, let axis, let first, let second):
            let newFirst = first.removing(leaf: target)
            let newSecond = second.removing(leaf: target)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let a?, let b?): return .split(id: id, axis: axis, first: a, second: b)
            }
        }
    }
}

/// Saved form of a split layout. Leaves carry only what is needed to recreate a pane.
indirect enum PaneSnapshot: Codable, Equatable {
    /// `primary` marks the tab's own session; every valid snapshot has exactly one.
    case leaf(cwd: String?, primary: Bool)
    case split(vertical: Bool, ratio: Double, first: PaneSnapshot, second: PaneSnapshot)

    var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .split(_, _, let first, let second): return first.leafCount + second.leafCount
        }
    }

    private var primaryCount: Int {
        switch self {
        case .leaf(_, let primary): return primary ? 1 : 0
        case .split(_, _, let first, let second): return first.primaryCount + second.primaryCount
        }
    }

    /// False for hand-edited or corrupt files: wrong primary count, too many panes, or a lone leaf.
    func isValid(maxPanes: Int) -> Bool {
        leafCount > 1 && leafCount <= maxPanes && primaryCount == 1
    }
}

extension PaneNode {
    /// Describes the tree for saving. `ratio` is looked up per split ID.
    func snapshot(primary: UUID, cwd: (UUID) -> String?, ratio: (UUID) -> Double) -> PaneSnapshot {
        switch self {
        case .leaf(let id):
            return .leaf(cwd: cwd(id), primary: id == primary)
        case .split(let id, let axis, let first, let second):
            return .split(
                vertical: axis == .vertical, ratio: ratio(id),
                first: first.snapshot(primary: primary, cwd: cwd, ratio: ratio),
                second: second.snapshot(primary: primary, cwd: cwd, ratio: ratio))
        }
    }
}
