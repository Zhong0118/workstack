import Foundation
import Testing
import WorkbenchCore
@testable import WorkbenchApp

@Test @MainActor func createAndApplyMovesSelectedMembersAndRollsBackRejectedLayout() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let backend = AppTestWindows()
    let first = backend.add(), second = backend.add(), unrelated = backend.add()
    let model = Workbench(directory: folder, controller: backend)
    model.update(Array(backend.windows.values), permission: true, screens: [AppTestWindows.screen])
    let ws = try #require(model.state.activeID)
    let peer = Workspace(name: "第二个工作区")
    model.change {
        $0.workspaces.append(peer); $0.prefs.switchMode = .concentrate
    }
    model.addGroup("原来的组", to: ws)
    let source = try #require(model.groupList.first?.id)
    model.bind(first, to: source)
    let before = model.state, windowsBefore = backend.windows, originalHistory = model.history
    backend.failFocus = first
    let failure = await model.createAndApplyGroup(name: "新组", workspace: peer.id, members: [first, second], preset: .columns)
    #expect(throws: (any Error).self) { try failure.get() }
    #expect(model.state == before && model.history == originalHistory)
    #expect(backend.windows == windowsBefore)
    #expect(model.journalCount == 0)
    backend.failFocus = nil
    let created = try await model.createAndApplyGroup(name: "新组", workspace: peer.id, members: [first, second], preset: .columns)
        .get()
    #expect(model.activeWorkspace?.groups.last?.id == created)
    #expect(model.state.activeID == peer.id)
    #expect(model.groupList.first(where: { $0.id == source })?.memberIDs.isEmpty == true)
    #expect(model.activeWorkspace?.groups.last?.memberIDs == [first, second])
    #expect(backend.windows[unrelated] == windowsBefore[unrelated])
    #expect(backend.windows[first]?.minimized == false)
    #expect(backend.windows[first]?.focused == true)
    #expect(try LocalFile.read(WorkbenchState.self, from: model.configURL) == model.state)
}

@Test @MainActor func creatingAfterReleaseUsesCurrentMinimizedState() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let system = AppTestWindows(), first = system.add(), peer = system.add()
    let model = Workbench(directory: folder, controller: system)
    try model.change { $0.workspaces[0].groups = [WindowGroup(name: "旧组", floating: [first])] }.get()
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    try await model.execute([.conceal(first)])
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    model.release(first)
    while model.busy { await Task.yield() }
    #expect(system.windows[first]?.minimized == false)
    #expect(model.windows.first(where: { $0.id == first })?.minimized == true)
    let ws = try #require(model.state.activeID)
    _ = try await model.createAndApplyGroup(name: "新组", workspace: ws, members: [first, peer], preset: .columns).get()
    #expect(system.focusedIDs.last == first)
    #expect(system.windows[first]?.frame.minX == AppTestWindows.screen.frame.minX)
}
