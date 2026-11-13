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
