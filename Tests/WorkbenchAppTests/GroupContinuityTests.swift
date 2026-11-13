import Foundation
import Testing
import WorkbenchCore
@testable import WorkbenchApp

@MainActor private func settle(_ model: Workbench) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    try #require(!model.busy)
}

@Test @MainActor func releasingForegroundTabRevealsItsNeighborInPlace() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), first = system.add(), second = system.add(), third = system.add(minimized: true)
    let model = Workbench(directory: directory, controller: system)
    let original = try await system.read(first)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let workspace = try #require(model.state.activeID)
    let group = try await model.createAndApplyGroup(
        name: "标签组", workspace: workspace, members: [first, third, second], preset: .tabs
    ).get()
    let paneFrame = try await system.read(first).frame
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    try #require(system.windows[first]?.focused == true && system.windows[second]?.minimized == true)
    model.release(first)
    try await settle(model)
    #expect(model.groupList.first(where: { $0.id == group })?.root?.panes.first?.active == second)
    #expect(system.windows[first]?.frame == original.frame)
    #expect(system.windows[second]?.frame == paneFrame)
    #expect(system.windows[second]?.minimized == false && system.windows[second]?.focused == true)
    #expect(system.windows[third]?.minimized == true)
    #expect(try LocalFile.read(WorkbenchState.self, from: model.configURL) == model.state)
}

@Test @MainActor func creatingSecondTiledGroupMakesRoomOnlyInAppliedGroups() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), first = system.add(), second = system.add(), third = system.add(), floating = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let workspace = try #require(model.state.activeID)
    model.change { $0.workspaces[0].groups.append(WindowGroup(name: "浮窗", floating: [floating])) }
    let original = system.windows[floating]
    _ = try await model.createAndApplyGroup(name: "第一组", workspace: workspace, members: [first], preset: .tabs).get()
    let previous = model.state, previousFrame = try await system.read(first).frame
    #expect(previousFrame == AppTestWindows.screen.frame)
    system.failFocus = second
    let failure = await model.createAndApplyGroup(name: "第二组", workspace: workspace, members: [second, third], preset: .columns)
    #expect(throws: (any Error).self) { try failure.get() }
    #expect(model.state == previous && system.windows[first]?.frame == previousFrame)
    system.failFocus = nil
    _ = try await model.createAndApplyGroup(name: "第二组", workspace: workspace, members: [second, third], preset: .columns).get()
    let a = try await system.read(first), b = try await system.read(second), c = try await system.read(third)
    #expect(a.frame.maxX <= b.frame.minX && b.frame.maxX <= c.frame.minX)
    #expect(b.focused && system.windows[floating] == original)
}

@Test @MainActor func switchingMemberIntoFreeGroupRevealsSourcePaneWithoutStealingFocus() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), first = system.add(), next = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let workspace = try #require(model.state.activeID)
    _ = try await model.createAndApplyGroup(name: "原组", workspace: workspace, members: [first, next], preset: .tabs).get()
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    try #require(system.windows[next]?.minimized == true)
    _ = try await model.createAndApplyGroup(name: "浮窗", workspace: workspace, members: [first], preset: .free).get()
    #expect(system.windows[next]?.minimized == false)
    #expect(system.windows[next]?.frame == AppTestWindows.screen.frame)
    #expect(system.windows[first]?.focused == true)
}

@Test @MainActor func failedTabHandoffKeepsMembershipAndPhysicalWindows() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), first = system.add(), next = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let workspace = try #require(model.state.activeID)
    _ = try await model.createAndApplyGroup(name: "标签组", workspace: workspace, members: [first, next], preset: .tabs).get()
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let before = model.state, history = model.history, journal = model.coordinator.journal, physical = system.windows
    system.failFocus = next
    model.release(first)
    try await settle(model)
    #expect(model.noticeIsFailure && model.state == before && model.history == history)
    #expect(system.windows == physical && model.coordinator.journal == journal)
}

@Test @MainActor func releasingBackgroundPaneDoesNotTakeKeyboardFocus() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), first = system.add(), second = system.add(), unrelated = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let workspace = try #require(model.state.activeID)
    _ = try await model.createAndApplyGroup(name: "后台组", workspace: workspace, members: [first, second], preset: .tabs).get()
    try await system.focus(unrelated)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let focusRequests = system.focusedIDs
    model.release(first)
    try await settle(model)
    #expect(system.windows[second]?.minimized == false && system.windows[unrelated]?.focused == true)
    #expect(system.focusedIDs == focusRequests)
}
