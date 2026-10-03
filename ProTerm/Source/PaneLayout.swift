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
