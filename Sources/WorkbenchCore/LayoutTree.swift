import Foundation

public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }
public enum LayoutEdge: String, CaseIterable, Codable, Sendable { case center, left, right, top, bottom }
public enum LayoutPreset: String, CaseIterable, Codable, Sendable {
    case columns, rows, threeColumns, mainAndStack, grid, tabs, free
}

public struct LayoutPane: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let tabs: [UUID]
    public let active: UUID?
}

public indirect enum LayoutNode: Codable, Equatable, Identifiable, Sendable {
    case pane(id: UUID, tabs: [UUID], active: UUID?)
    case split(id: UUID, axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)

    public var id: UUID {
        switch self {
        case let .pane(id, _, _), let .split(id, _, _, _, _): id
        }
    }

    public var panes: [LayoutPane] {
        var result = [LayoutPane]()
        collectPanes(into: &result)
        return result
    }

    private func collectPanes(into result: inout [LayoutPane]) {
        switch self {
        case let .pane(id, tabs, active):
            result.append(LayoutPane(id: id, tabs: tabs, active: active))
        case let .split(_, _, _, first, second):
            first.collectPanes(into: &result)
            second.collectPanes(into: &result)
        }
    }

    // Removing the last tab collapses its branch. Untouched placeholders in
    // saved templates survive while the user populates the other panes.
    public func removing(_ member: UUID) -> LayoutNode? {
        switch self {
        case let .pane(id, tabs, active):
            guard let index = tabs.firstIndex(of: member) else { return self }
            let rest = tabs.filter { $0 != member }
            guard !rest.isEmpty else { return nil }
            let next = active == member ? rest[min(index, rest.count - 1)] : active
            return .pane(id: id, tabs: rest, active: next)
        case let .split(id, axis, ratio, first, second):
            let left = first.removing(member), right = second.removing(member)
            guard let left, let right else { return left ?? right }
            return .split(id: id, axis: axis, ratio: ratio, first: left, second: right)
        }
    }

    private func replacing(_ target: UUID, with transform: (LayoutNode) -> LayoutNode) -> LayoutNode {
        if id == target { return transform(self) }
        guard case let .split(id, axis, ratio, first, second) = self else { return self }
        return .split(
            id: id, axis: axis, ratio: ratio, first: first.replacing(target, with: transform),
            second: second.replacing(target, with: transform))
    }

    public func inserting(_ member: UUID, at paneID: UUID, edge: LayoutEdge = .center) -> LayoutNode {
        guard let pane = panes.first(where: { $0.id == paneID }) else { return self }
        if pane.tabs.contains(member), edge == .center || pane.tabs.count == 1 {
            return activating(member)
        }
        guard let tree = removing(member) else { return self }
        return tree.replacing(paneID) { target in
            guard case let .pane(id, tabs, _) = target else { return target }
            guard !tabs.isEmpty, edge != .center else {
                return .pane(id: id, tabs: tabs + [member], active: member)
            }
            let newPane = LayoutNode.pane(id: UUID(), tabs: [member], active: member)
            let before = edge == .left || edge == .top
            return .split(
                id: UUID(), axis: edge == .left || edge == .right ? .horizontal : .vertical,
                ratio: 0.5, first: before ? newPane : target, second: before ? target : newPane)
        }
    }

    public func activating(_ member: UUID) -> LayoutNode {
        guard let pane = panes.first(where: { $0.tabs.contains(member) }) else { return self }
        return replacing(pane.id) { _ in .pane(id: pane.id, tabs: pane.tabs, active: member) }
    }

    public func reordering(_ member: UUID, to index: Int) -> LayoutNode {
        guard let pane = panes.first(where: { $0.tabs.contains(member) }) else { return self }
        var tabs = pane.tabs.filter { $0 != member }
        tabs.insert(member, at: min(max(0, index), tabs.count))
        return replacing(pane.id) { _ in .pane(id: pane.id, tabs: tabs, active: pane.active) }
    }

    public func resizing(split: UUID, ratio: Double) -> LayoutNode {
        guard ratio.isFinite else { return self }
        return replacing(split) { node in
            guard case let .split(id, axis, _, first, second) = node else { return node }
            return .split(id: id, axis: axis, ratio: min(0.98, max(0.02, ratio)), first: first, second: second)
        }
    }

    public func swappingPanes(_ a: UUID, _ b: UUID) -> LayoutNode {
        let leaves = panes
        guard a != b, let first = leaves.first(where: { $0.id == a }),
            let second = leaves.first(where: { $0.id == b })
        else { return self }
        func swap(_ node: LayoutNode) -> LayoutNode {
            switch node {
            case .pane where node.id == a: .pane(id: second.id, tabs: second.tabs, active: second.active)
            case .pane where node.id == b: .pane(id: first.id, tabs: first.tabs, active: first.active)
            case .pane: node
            case let .split(id, axis, ratio, left, right):
                .split(id: id, axis: axis, ratio: ratio, first: swap(left), second: swap(right))
            }
        }
        return swap(self)
    }

    public func emptyCopy() -> LayoutNode {
        switch self {
        case .pane: .pane(id: UUID(), tabs: [], active: nil)
        case let .split(_, axis, ratio, first, second):
            .split(id: UUID(), axis: axis, ratio: ratio, first: first.emptyCopy(), second: second.emptyCopy())
        }
    }
}

public struct WindowGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var root: LayoutNode?
    public var floating: [UUID]
    public var displayID: String?
    public var zoomedPane: UUID?
    public private(set) var preset: LayoutPreset?

    public init(id: UUID = UUID(), name: String, root: LayoutNode? = nil, floating: [UUID] = [], displayID: String? = nil) {
        self.id = id
        self.name = name
        self.root = root
        self.floating = floating
        self.displayID = displayID
    }

    public var memberIDs: [UUID] { (root?.panes.flatMap(\.tabs) ?? []) + floating }

    public mutating func insert(_ member: UUID, at pane: UUID? = nil, edge: LayoutEdge = .center) {
        if preset == .free, pane == nil, edge == .center {
            if !floating.contains(member) { floating.append(member) }
            return
        }
        if let root {
            let leaves = root.panes
            let target =
                pane ?? leaves.first(where: { $0.tabs.contains(member) })?.id
                ?? leaves.first(where: { $0.tabs.isEmpty })?.id ?? leaves[0].id
            guard leaves.contains(where: { $0.id == target }) else { return }
            self.root = root.inserting(member, at: target, edge: edge)
        } else {
            guard pane == nil else { return }
            root = .pane(id: UUID(), tabs: [member], active: member)
        }
        floating.removeAll { $0 == member }
        clearMissingZoom()
    }

    public mutating func remove(_ member: UUID) {
        root = root?.removing(member)
        floating.removeAll { $0 == member }
        clearMissingZoom()
    }

    public mutating func activate(_ member: UUID) { root = root?.activating(member) }
    public mutating func reorder(_ member: UUID, to index: Int) { root = root?.reordering(member, to: index) }
    public mutating func resize(split: UUID, ratio: Double) { root = root?.resizing(split: split, ratio: ratio) }
    public mutating func swapPanes(_ a: UUID, _ b: UUID) { root = root?.swappingPanes(a, b) }

    public mutating func setFloating(_ member: UUID, _ shouldFloat: Bool) {
        guard floating.contains(member) != shouldFloat else { return }
        if shouldFloat {
            remove(member)
            floating.append(member)
        } else {
            if preset == .free { preset = nil }
            insert(member)
        }
    }

    public mutating func toggleZoom(_ pane: UUID) {
        guard root?.panes.contains(where: { $0.id == pane }) == true else { return }
        zoomedPane = zoomedPane == pane ? nil : pane
    }

    private mutating func clearMissingZoom() {
        if let zoomedPane, root?.panes.contains(where: { $0.id == zoomedPane }) != true { self.zoomedPane = nil }
    }

    public mutating func apply(_ preset: LayoutPreset) {
        let members = memberIDs
        self.preset = preset
        zoomedPane = nil
        floating = preset == .free ? members : []
        root = preset.makeTree(for: members)
    }

    public func emptyCopy(name: String) -> WindowGroup {
        var copy = WindowGroup(name: name, root: root?.emptyCopy(), displayID: displayID)
        copy.preset = preset
        return copy
    }
}

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var groups: [WindowGroup]

    public init(id: UUID = UUID(), name: String, groups: [WindowGroup] = []) {
        self.id = id
        self.name = name
        self.groups = groups
    }

    public func emptyCopy(name: String) -> Workspace {
        Workspace(name: name, groups: groups.map { $0.emptyCopy(name: $0.name) })
    }
}

public extension WindowGroup {
    mutating func resetRatios() {
        func reset(_ node: LayoutNode) -> (LayoutNode, Int) {
            switch node {
            case .pane: return (node, 1)
            case let .split(id, axis, _, first, second):
                let (a, ac) = reset(first), (b, bc) = reset(second)
                return (.split(id: id, axis: axis, ratio: Double(ac) / Double(ac + bc), first: a, second: b), ac + bc)
            }
        }
        root = root.map { reset($0).0 }
    }

    mutating func unstack(_ pane: UUID) {
        guard let tree = root, let leaf = tree.panes.first(where: { $0.id == pane }), leaf.tabs.count > 1 else { return }
        func expand(_ node: LayoutNode) -> LayoutNode {
            switch node {
            case .pane where node.id == pane:
                return LayoutPreset.grid.makeTree(for: leaf.tabs) ?? node
            case .pane: return node
            case let .split(id, axis, ratio, a, b):
                return .split(id: id, axis: axis, ratio: ratio, first: expand(a), second: expand(b))
            }
        }
        root = expand(tree)
        if zoomedPane == pane { zoomedPane = nil }
    }
}
