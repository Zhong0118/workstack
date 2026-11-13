import Foundation
import CoreGraphics
#if canImport(Testing)
    import Testing
#endif
#if canImport(WorkbenchCore)
    import WorkbenchCore
#endif

enum LayoutCheckError: Error { case failed(String, Int) }

func runLayoutChecks() throws {
    func check(_ condition: @autoclosure () -> Bool, _ line: Int = #line) throws {
        if !condition() { throw LayoutCheckError.failed("layout assertion", line) }
    }
    let a = UUID(), b = UUID(), c = UUID()
    var group = WindowGroup(name: "Editors")
    group.insert(a)
    group.insert(b)
    group.insert(c)
    let first = group.root!.id
    group.reorder(c, to: 0)
    group.activate(b)
    try check(group.root!.panes[0].tabs == [c, a, b])
    try check(group.root!.panes[0].active == b)
    group.insert(a, at: first, edge: .right)
    let second = group.root!.panes[1].id
    try check(group.root!.panes.map(\.tabs) == [[c, b], [a]])
    group.insert(a)
    try check(group.root!.panes.map(\.tabs) == [[c, b], [a]])
    group.resize(split: group.root!.id, ratio: 0.25)
    let area = CGRect(x: -800, y: 25, width: 1000, height: 600)
    let placements = group.placements(in: area, gap: 0, minimums: [c: CGSize(width: 400, height: 100)])
    try check(placements.map(\.frame.width) == [400, 600])
    try check(placements[1].frame.origin == CGPoint(x: -400, y: 25))
    group.toggleZoom(second)
    try check(group.placements(in: area).map(\.frame) == [area])
    group.toggleZoom(second)
    group.swapPanes(first, second)
    try check(group.root!.panes.map(\.id) == [second, first])
    group.insert(a, at: second, edge: .bottom)
    try check(group.root!.panes.count == 2)
    group.setFloating(a, true)
    try check(group.floating == [a] && group.root!.id == first)
    group.setFloating(a, false)
    try check(group.floating.isEmpty && Set(group.memberIDs) == [a, b, c])
    group.remove(b)
    try check(group.root!.panes[0].active != b)

    for preset in LayoutPreset.allCases {
        group.apply(preset)
        try check(Set(group.memberIDs) == [a, c] && group.memberIDs.count == 2)
    }
    group.apply(.threeColumns)
    let workspace = Workspace(name: "Work", groups: [group])
    let copy = workspace.emptyCopy(name: "Other")
    try check(copy.id != workspace.id && copy.groups[0].id != group.id)
    try check(copy.groups[0].memberIDs.isEmpty)
    try check(copy.groups[0].root!.panes.count == 3)
    var template = copy.groups[0]
    template.insert(a)
    template.insert(b)
    try check(template.root!.panes.map(\.tabs) == [[a], [b], []])
    let encoded = try JSONEncoder().encode(workspace)
    let decoded = try JSONDecoder().decode(Workspace.self, from: encoded)
    try check(decoded == workspace)
    var loose = WindowGroup(name: "Floating")
    loose.setFloating(a, true)
    loose.setFloating(a, true)
    try check(loose.floating == [a] && loose.root == nil)
    loose.apply(.free)
    loose.insert(b)
    loose.setFloating(a, false)
    try check(loose.floating == [b] && loose.root?.panes.first?.tabs == [a])

    let order = [a, b, c, UUID(), UUID(), UUID(), UUID()]
    var ordered = WindowGroup(name: "Ordered", floating: order)
    for preset in LayoutPreset.allCases {
        ordered.apply(preset)
        try check(ordered.memberIDs == order)
        ordered.apply(preset)
        try check(ordered.memberIDs == order)
    }
    let stale = UUID()
    let before = template
    template.insert(c, at: stale)
    template.resize(split: template.root!.id, ratio: .nan)
    template.swapPanes(first, stale)
    try check(template == before)

    // Sum child minima along a split and take their maximum across a split.
    var nested = WindowGroup(name: "Nested")
    nested.insert(a)
    let top = nested.root!.id
    nested.insert(b, at: top, edge: .bottom)
    nested.insert(c, at: top, edge: .right)
    let nestedFrames = nested.placements(
        in: area, gap: 10,
        minimums: [
            a: CGSize(width: 500, height: 410),
            b: CGSize(width: 10, height: 40),
            c: CGSize(width: 10, height: 120),
        ])
    try check(nestedFrames.map(\.frame.height) == [410, 410, 180])
    try check(nestedFrames.map(\.frame.width) == [500, 490, 1000])
    try check(nestedFrames[2].frame.minY == 445)
    nested.remove(a)
    try check(nested.root!.panes.map(\.tabs) == [[c], [b]])
    nested.remove(c)
    nested.remove(b)
    try check(nested.root == nil)
    let tiny = template.placements(in: CGRect(x: 0, y: 0, width: 12, height: 8), gap: 20)
    try check(tiny.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 12 && $0.frame.width >= 0 })
}

#if canImport(WorkbenchCore) || LAYOUT_WITH_STATE
    func runLayoutValidationChecks() throws {
        let window = UUID()
        var first = WindowGroup(name: "First")
        first.insert(window)
        var second = WindowGroup(name: "Second")
        second.setFloating(window, true)
        var state = WorkbenchState()
        state.workspaces = [Workspace(name: "Original", groups: [first])]
        state.templates = [first.emptyCopy(name: "Saved")]
        try state.validate()
        func rejects(_ edit: (inout WorkbenchState) -> Void) throws {
            var invalid = state
            edit(&invalid)
            do { try invalid.validate() } catch StorageError.invalidConfiguration { return }
            throw LayoutCheckError.failed("invalid document accepted", #line)
        }
        try rejects { $0.workspaces.append(Workspace(name: "Duplicate physical membership", groups: [second])) }
        try rejects { $0.templates = [first] }
        try rejects {
            $0.workspaces[0].groups[0].root = .pane(id: UUID(), tabs: [window], active: UUID())
        }
    }
#endif

#if LAYOUT_STANDALONE
    private func benchmarkLayout() throws {
        for count in [32, 128, 512] {
            let members = (0..<count).map { _ in UUID() }
            var group = WindowGroup(name: "Benchmark", floating: members)
            group.apply(.grid)
            let area = CGRect(x: -2560, y: 24, width: 2560, height: 1416)
            for _ in 0..<16 { _ = group.placements(in: area) }
            var samples = [Double](), checksum = 0.0
            for _ in 0..<300 {
                let start = DispatchTime.now().uptimeNanoseconds
                let placements = group.placements(in: area)
                let end = DispatchTime.now().uptimeNanoseconds
                guard placements.count == count else { throw LayoutCheckError.failed("missing pane", #line) }
                checksum += placements.last!.frame.width
                samples.append(Double(end - start) / 1_000)
            }
            samples.sort()
            print(
                String(
                    format: "%d panes, 300 solves; median %.1f µs, p95 %.1f µs (checksum %.0f)",
                    count, samples[149], samples[284], checksum))
        }
    }

    @main struct LayoutChecksMain {
        static func main() throws {
            try runLayoutChecks()
            #if LAYOUT_WITH_STATE
                try runLayoutValidationChecks()
            #endif
            print("Layout checks passed")
            if CommandLine.arguments.contains("--benchmark") { try benchmarkLayout() }
        }
    }
#elseif canImport(Testing)
    @Test func layoutEditingAndGeometry() throws { try runLayoutChecks() }
    @Test func layoutMemberAndNodeValidation() throws { try runLayoutValidationChecks() }
#endif
