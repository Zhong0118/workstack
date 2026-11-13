import Foundation
import CoreGraphics

extension LayoutPreset {
    func makeTree(for members: [UUID]) -> LayoutNode? {
        func pane(_ tabs: [UUID]) -> LayoutNode {
            .pane(id: UUID(), tabs: tabs, active: tabs.first)
        }
        func line(_ nodes: ArraySlice<LayoutNode>, along axis: SplitAxis) -> LayoutNode {
            let count = nodes.count
            if count == 1 { return nodes.first! }
            let half = count / 2
            return .split(
                id: UUID(), axis: axis, ratio: Double(half) / Double(count),
                first: line(nodes.prefix(half), along: axis), second: line(nodes.dropFirst(half), along: axis))
        }
        switch self {
        case .free: return nil
        case .tabs: return pane(members)
        case .rows, .columns, .threeColumns:
            let count = self == .threeColumns ? 3 : 2
            var remaining = members[...]
            let panes = (0..<count).map { index in
                let capacity = members.count / count + (index < members.count % count ? 1 : 0)
                let tabs = remaining.prefix(capacity)
                remaining = remaining.dropFirst(capacity)
                return pane(Array(tabs))
            }
            return line(panes[...], along: self == .rows ? .vertical : .horizontal)
        case .mainAndStack:
            let main = pane(Array(members.prefix(1)))
            let stack = members.dropFirst().map { pane([$0]) }
            return .split(
                id: UUID(), axis: .horizontal, ratio: 0.6, first: main,
                second: stack.isEmpty ? pane([]) : line(stack[...], along: .vertical))
        case .grid:
            guard !members.isEmpty else { return pane([]) }
            let columns = Int(ceil(sqrt(Double(members.count))))
            var rows = [LayoutNode]()
            for offset in stride(from: 0, to: members.count, by: columns) {
                let cells = members[offset..<min(offset + columns, members.count)].map { pane([$0]) }
                rows.append(line(cells[...], along: .horizontal))
            }
            return line(rows[...], along: .vertical)
        }
    }
}

public struct PanePlacement: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let tabs: [UUID]
    public let active: UUID?
    public let frame: CGRect
}

public extension WindowGroup {
    /// Window geometry and safe areas use the Accessibility API's top-left coordinate system.
    func placements(in area: CGRect, gap: CGFloat = 6, minimums: [UUID: CGSize] = [:]) -> [PanePlacement] {
        guard let root, area.origin.x.isFinite, area.origin.y.isFinite,
            area.size.width.isFinite, area.size.height.isFinite, area.size.width > 0, area.size.height > 0
        else { return [] }
        if let zoomedPane, let leaf = root.panes.first(where: { $0.id == zoomedPane }) {
            return [PanePlacement(id: leaf.id, tabs: leaf.tabs, active: leaf.active, frame: area)]
        }
        let spacing = gap.isFinite ? max(0, gap) : 0
        var minimumSizes = [UUID: CGSize]()
        func measure(_ node: LayoutNode) -> CGSize {
            var size = CGSize(width: 1, height: 1)
            switch node {
            case let .pane(_, tabs, _):
                for tab in tabs {
                    guard let required = minimums[tab] else { continue }
                    if required.width.isFinite { size.width = max(size.width, required.width) }
                    if required.height.isFinite { size.height = max(size.height, required.height) }
                }
            case let .split(_, axis, _, first, second):
                let a = measure(first), b = measure(second)
                if axis == .horizontal {
                    size = CGSize(width: a.width + spacing + b.width, height: max(a.height, b.height))
                } else {
                    size = CGSize(width: max(a.width, b.width), height: a.height + spacing + b.height)
                }
            }
            minimumSizes[node.id] = size
            return size
        }
        _ = measure(root)
        var placements = [PanePlacement]()
        func place(_ node: LayoutNode, in rect: CGRect) {
            switch node {
            case let .pane(id, tabs, active):
                placements.append(PanePlacement(id: id, tabs: tabs, active: active, frame: rect))
            case let .split(_, axis, ratio, first, second):
                let horizontal = axis == .horizontal
                let axisSize: KeyPath<CGSize, CGFloat> = horizontal ? \.width : \.height
                let length = rect.size[keyPath: axisSize]
                let firstMin = minimumSizes[first.id]![keyPath: axisSize]
                let secondMin = minimumSizes[second.id]![keyPath: axisSize]
                let gutter = min(spacing, max(0, length - firstMin - secondMin))
                let available = length - gutter
                let firstLength: CGFloat
                if firstMin + secondMin > available {
                    // A screen smaller than the native minima still gets a bounded preview.
                    firstLength = available * (firstMin / (firstMin + secondMin))
                } else {
                    let ideal = available * (ratio.isFinite ? ratio : 0.5)
                    firstLength = min(max(ideal.rounded(), firstMin), available - secondMin)
                }
                var a = rect, b = rect
                if horizontal {
                    a.size.width = firstLength
                    b.origin.x += firstLength + gutter
                    b.size.width = available - firstLength
                } else {
                    a.size.height = firstLength
                    b.origin.y += firstLength + gutter
                    b.size.height = available - firstLength
                }
                place(first, in: a)
                place(second, in: b)
            }
        }
        place(root, in: area)
        return placements
    }
}
