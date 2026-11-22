import Foundation
import Testing
import WorkbenchCore
@testable import MacWindows
@testable import WorkbenchApp

private func sampleWindow() -> LiveWindow {
    let id = UUID()
    return LiveWindow(
        id: id, bundleID: "test.app", appName: "Test", title: "", frame: CGRect(x: 1, y: 2, width: 300, height: 200),
        kind: .normal, minimized: false, fullscreen: false, movable: true, resizable: true, minimizable: true, focused: false,
        identity: WindowIdentity(bundleID: "test.app", pid: 1, launched: Date(), identifier: id.uuidString))
}

@Test @MainActor func layoutFinishesBeforeSingleFinalFocus() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = Workbench(directory: directory)
    let members = [sampleWindow(), sampleWindow(), sampleWindow()]
    model.update(
        members, permission: true,
        screens: [DisplayArea(id: "test", name: "test", frame: CGRect(x: 0, y: 0, width: 1200, height: 900))])
    var group = WindowGroup(name: "fixture", floating: members.map(\.id))
    group.apply(.threeColumns)
    let plan = model.plannedCommands(for: [group], peers: [group], mode: .arrange)
    let focuses = plan.enumerated().compactMap { index, command -> Int? in
        if case .raise = command { return index }
        return nil
    }
    #expect(focuses == [plan.count - 1])
    #expect(plan.filter { if case .place = $0 { true } else { false } }.count == 3)
}

@Test @MainActor func focusModeLeavesFramesAndInactiveTabsAlone() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = Workbench(directory: directory)
    let a = sampleWindow(), b = sampleWindow()
    var minimized = sampleWindow()
    minimized.minimized = true
    model.update(
        [a, b, minimized], permission: true,
        screens: [
            DisplayArea(id: "test", name: "test", frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        ])
    var g = WindowGroup(name: "group", floating: [a.id, b.id, minimized.id])
    g.apply(.tabs)
    g.activate(b.id)
    let plan = model.plannedCommands(for: [g], peers: [g], mode: .focus)
    #expect(plan.map(\.member) == [b.id, b.id])
    #expect(
        plan.allSatisfy { command in
            switch command {
            case .reveal, .raise: true;
            default: false
            }
        })
    let missing = UUID()
    g.insert(missing)
    let workspace = Workspace(name: "fixture", groups: [g])
    #expect(model.missingCount(in: workspace) == 1)
}

@Test @MainActor func activationWithoutPermissionKeepsPreviousWorkspace() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = Workbench(directory: directory)
    let w = sampleWindow()
    var g = WindowGroup(name: "组")
    g.insert(w.id)
    let target = Workspace(name: "项目", groups: [g])
    model.change { $0.workspaces.append(target) }
    let previous = model.state
    model.update([], permission: false, screens: [])
    model.activate(target.id)
    while model.busy { await Task.yield() }
    #expect(model.state == previous)
    #expect(model.failedOperations == 1)
    #expect(model.notice?.contains("辅助功能") == true)
    #expect(model.journalCount == 0)
}

@Test func oldSwitchPreferencesMapToThreeModes() throws {
    var prefs = Preferences()
    #expect(prefs.switchMode == .arrange)
    prefs.switchLayouts = false
    #expect(prefs.switchMode == .focus)
    prefs.hidePrevious = true
    #expect(prefs.switchMode == .concentrate)
    prefs.switchMode = .focus
    #expect(!prefs.hidePrevious && !prefs.switchLayouts)
    let data = try JSONEncoder().encode(prefs)
    #expect(try JSONDecoder().decode(Preferences.self, from: data).switchMode == .focus)
}

@Test @MainActor func ambiguousIdentityCannotConcealEitherWindow() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = Workbench(directory: directory)
    let a = sampleWindow()
    var b = a
    b.id = UUID()
    model.update([a, b], permission: true, screens: [])
    #expect(!model.canSafelyMinimize(a.id))
    #expect(!model.canSafelyMinimize(b.id))
}

@Test @MainActor func staleFormerAppFocusDoesNotChangeItsActiveTab() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = Workbench(directory: folder)
    let saved = sampleWindow()
    var stale = sampleWindow(), front = sampleWindow()
    stale.focused = true
    front.focused = true
    front.identity.pid = 2
    var group = WindowGroup(name: "后台窗口", floating: [saved.id, stale.id])
    group.apply(.tabs)
    group.activate(saved.id)
    try model.change { $0.workspaces[0].groups = [group] }.get()
    let perProcess = [stale.identity.pid: [stale, saved], front.identity.pid: [front]]
    // Each process was scanned while it was frontmost. Together those stale flags cannot both be correct.
    model.update(
        MacWindows.visibleSnapshot(perProcess, frontmost: front.identity.pid), permission: true, screens: [AppTestWindows.screen])
    #expect(model.groupList.first?.root?.panes.first?.active == saved.id)
}

@Test @MainActor func switcherOffersOnlyWindowsThatFocusCanRaise() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = Workbench(directory: directory)
    let normal = sampleWindow()
    var dialog = sampleWindow(), fullscreen = sampleWindow(), minimized = sampleWindow()
    dialog.kind = .dialog
    fullscreen.fullscreen = true
    minimized.minimized = true
    #expect([normal, dialog, fullscreen, minimized].map(model.canFocus) == [true, false, false, false])
}

@Test func minimizingInactiveTabsIsOptInAndReadsExistingFiles() throws {
    // A file written before the option existed always says `minimizeTabs: true`.
    let legacy = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(Preferences()))
    #expect(legacy.minimizeTabs && legacy.minimizeInactiveTabs == nil && !legacy.minimizesInactiveTabs)
    var prefs = legacy
    prefs.minimizesInactiveTabs = true
    let saved = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
    #expect(saved.minimizesInactiveTabs && saved.minimizeTabs)
    prefs.minimizesInactiveTabs = false
    #expect(!prefs.minimizesInactiveTabs && !prefs.minimizeTabs)
}

@Test @MainActor func arrangingStacksInactiveTabsUnlessMinimizingIsEnabled() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = Workbench(directory: directory)
    let members = [sampleWindow(), sampleWindow(), sampleWindow()]
    let screen = DisplayArea(id: "test", name: "test", frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
    model.update(members, permission: true, screens: [screen])
    var group = WindowGroup(name: "fixture", floating: members.map(\.id))
    group.apply(.tabs)
    func frames(_ plan: [WindowCommand], stacked: Bool) -> [CGRect] {
        plan.compactMap { command in
            switch command {
            case .place(_, let rect) where !stacked: rect
            case .stack(_, let rect) where stacked: rect
            default: nil
            }
        }
    }
    let plan = model.plannedCommands(for: [group], peers: [group], mode: .arrange)
    let active = frames(plan, stacked: false)
    #expect(active.count == 1 && frames(plan, stacked: true) == [active[0], active[0]])
    #expect(!plan.contains { if case .conceal = $0 { true } else { false } })

    var document = model.state
    document.prefs.minimizesInactiveTabs = true
    let minimizing = model.plannedCommands(for: [group], peers: [group], mode: .arrange, document: document)
    #expect(frames(minimizing, stacked: true).isEmpty)
    #expect(minimizing.filter { if case .conceal = $0 { true } else { false } }.count == 2)
}

@Test func stripWaitsForAMovingWindowToSettle() {
    let start = ContinuousClock.now
    let home = CGRect(x: 100, y: 100, width: 800, height: 600)
    var motion = StripMotion()
    // A window seen for the first time is at rest.
    motion.observe(home, at: start)
    #expect(motion.unsettled(at: start) == nil)

    // Each new frame restarts the wait, so the strip stays away for the whole drag.
    let dragged = home.offsetBy(dx: 60, dy: 0)
    motion.observe(dragged, at: start + .milliseconds(100))
    #expect(motion.unsettled(at: start + .milliseconds(150)) == start + .milliseconds(100) + StripMotion.settle)
    let dropped = home.offsetBy(dx: 120, dy: 40)
    motion.observe(dropped, at: start + .milliseconds(250))
    #expect(motion.unsettled(at: start + .milliseconds(400)) != nil)
    motion.observe(dropped, at: start + .milliseconds(400))
    #expect(motion.unsettled(at: start + .milliseconds(250) + StripMotion.settle) == nil)
}

@Test func stripStaysAttachedAcrossStackedTabsAndDetachesOnAMoveEvent() {
    let start = ContinuousClock.now
    let pane = CGRect(x: 0, y: 30, width: 900, height: 700)
    var motion = StripMotion()
    motion.observe(pane, at: start)
    // The next tab's application rounded its size by a couple of points.
    motion.observe(pane.insetBy(dx: 1, dy: 1.5), at: start + .milliseconds(50))
    #expect(motion.unsettled(at: start + .milliseconds(50)) == nil)

    // A move event is known before the frame it leads to, and that frame does not restart the wait.
    motion.nudge(at: start + .milliseconds(60))
    #expect(motion.unsettled(at: start + .milliseconds(61)) != nil)
    motion.observe(pane.offsetBy(dx: 80, dy: 0), at: start + .milliseconds(190))
    #expect(motion.unsettled(at: start + .milliseconds(60) + StripMotion.settle) == nil)

    // Without an event, as when an application reports none, the new frame is the only signal.
    motion.observe(pane, at: start + .seconds(2))
    #expect(motion.unsettled(at: start + .seconds(2) + .milliseconds(150)) != nil)
}

@Test @MainActor func selectingTabAcrossWorkspacesRespectsFocusMode() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), first = system.add(), second = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let group = WindowGroup(name: "Tabs", root: .pane(id: UUID(), tabs: [first, second], active: first))
    let target = Workspace(name: "Target", groups: [group])
    try model.change {
        $0.workspaces.append(target)
        $0.prefs.switchMode = .focus
        $0.prefs.minimizesInactiveTabs = true
    }.get()
    let frame = system.windows[second]?.frame
    model.focus(second)
    while model.busy { await Task.yield() }
    #expect(model.state.activeID == target.id && system.focusedIDs.last == second)
    #expect(system.windows[second]?.frame == frame)
    #expect(system.windows[first]?.minimized == false)
    #expect(model.journalCount == 0)
}

@Test @MainActor func keyboardTabSwitchSkipsManuallyMinimizedWindows() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), first = system.add(), minimized = system.add(minimized: true), last = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let group = WindowGroup(name: "Tabs", root: .pane(id: UUID(), tabs: [first, minimized, last], active: first))
    try model.change { $0.workspaces[0].groups = [group] }.get()
    model.stepTab(1)
    while model.busy { await Task.yield() }
    #expect(system.focusedIDs.last == last)
    model.stepTab(-1)
    while model.busy { await Task.yield() }
    #expect(system.focusedIDs.last == first)
    #expect(system.windows[minimized]?.minimized == true)
}

@Test @MainActor func selectingClampedStackedTabStillFocusesIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), first = system.add(), constrained = system.add()
    system.minimumSizes[constrained] = CGSize(width: 1400, height: 500)
    system.windows[constrained]?.frame.size = CGSize(width: 1500, height: 900)
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let group = WindowGroup(name: "Tabs", root: .pane(id: UUID(), tabs: [first, constrained], active: first))
    try model.change { $0.workspaces[0].groups = [group] }.get()
    model.apply(group.id)
    while model.busy { await Task.yield() }
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    model.selectTab(constrained, group: group.id)
    while model.busy { await Task.yield() }
    #expect(model.failedOperations == 0)
    #expect(system.focusedIDs.last == constrained)
    #expect(model.groupList.first?.root?.panes.first?.active == constrained)
}
