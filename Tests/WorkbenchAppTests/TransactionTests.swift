import Foundation
import Testing
import WorkbenchCore
@testable import WorkbenchApp

@MainActor private func settle(_ model: Workbench) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!model.busy)
}

@Test @MainActor func undoKeepsHistoryWhenConfigurationWriteFails() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = Workbench(directory: directory)
    model.change { $0.workspaces[0].name = "before" }
    model.change { $0.workspaces[0].name = "after" }
    let history = model.history
    try FileManager.default.moveItem(at: model.configURL, to: directory.appendingPathComponent("original"))
    try FileManager.default.createDirectory(at: model.configURL, withIntermediateDirectories: false)
    model.undo()
    try await settle(model)
    #expect(model.state.workspaces[0].name == "after")
    #expect(model.history == history)
    #expect(model.failedOperations == 1)
    try FileManager.default.removeItem(at: model.configURL)
    model.undo()
    try await settle(model)
    #expect(model.state.workspaces[0].name == "before")
    #expect(try LocalFile.read(WorkbenchState.self, from: model.configURL) == model.state)
}

@Test @MainActor func rejectedChangeGivesFeedback() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = Workbench(directory: directory)
    let original = model.state
    model.busy = true
    model.change { $0.workspaces.removeAll() }
    #expect(model.state == original)
    #expect(model.notice != nil)
}

@Test @MainActor func removedMembersAreRestoredOnlyAfterChangeIsSaved() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), member = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    try model.change { $0.workspaces[0].groups = [WindowGroup(name: "A", floating: [member])] }.get()
    try await model.execute([.conceal(member)])
    let saved = model.state, history = model.history
    try FileManager.default.moveItem(at: model.configURL, to: directory.appendingPathComponent("original"))
    try FileManager.default.createDirectory(at: model.configURL, withIntermediateDirectories: false)
    let failed = model.change { $0.workspaces[0].groups.removeAll() }
    #expect(throws: (any Error).self) { try failed.get() }
    #expect(!model.busy)
    #expect(model.state == saved && model.history == history)
    #expect(system.windows[member]?.minimized == true && model.coordinator.journal.entries[member]?.minimizedByUs == true)
    try FileManager.default.removeItem(at: model.configURL)
    try model.change { $0.workspaces[0].groups.removeAll() }.get()
    try await settle(model)
    #expect(system.windows[member]?.minimized == false)
    #expect(model.journalCount == 0)
}

@Test @MainActor func rejectedRebindPreservesMembershipBindingsAndLease() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), missing = system.add(), spare = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    try model.change {
        $0.workspaces[0].groups = [WindowGroup(name: "A", floating: [missing])]
        $0.identities[missing] = system.windows[missing]?.identity
    }.get()
    try await model.execute([.conceal(missing)])
    system.windows[missing] = nil
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let saved = model.state, bindings = model.bindings, history = model.history, journal = model.coordinator.journal
    try FileManager.default.moveItem(at: model.configURL, to: directory.appendingPathComponent("original"))
    try FileManager.default.createDirectory(at: model.configURL, withIntermediateDirectories: false)
    let failed = model.rebind(missing, to: spare)
    #expect(throws: (any Error).self) { try failed.get() }
    #expect(model.state == saved && model.history == history && model.bindings == bindings)
    #expect(model.coordinator.journal == journal)
    try FileManager.default.removeItem(at: model.configURL)
    try model.rebind(missing, to: spare).get()
    #expect(model.state.memberIDs == [spare])
    #expect(model.coordinator.journal == journal)
    #expect(system.windows[spare]?.minimized == false)
}

@Test @MainActor func undoTabRestoresPriorFocusAndCanRetryAfterAXFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), peer = system.add(), first = system.add(), second = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let group = WindowGroup(name: "Tabs", root: .pane(id: UUID(), tabs: [first, second], active: first))
    try model.change { $0.workspaces[0].groups = [WindowGroup(name: "Peer", floating: [peer]), group] }.get()
    model.selectTab(second, group: group.id)
    try await settle(model)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let history = model.history, state = model.state, leases = model.coordinator.journal
    #expect(system.windows[first]?.minimized == true)
    system.failFocus = first
    model.undo()
    try await settle(model)
    #expect(model.history == history && model.state == state)
    #expect(system.windows[first]?.minimized == true && system.windows[second]?.minimized == false)
    #expect(model.coordinator.journal == leases)
    system.failFocus = nil
    model.undo()
    try await settle(model)
    #expect(model.history.count == history.count - 1)
    #expect(model.groupList.last?.root?.panes.first?.active == first)
    #expect(system.focusedIDs.last == first && system.windows[second]?.minimized == true)
}

@Test @MainActor func releaseFailureKeepsLeaseForRecoveryRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), id = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    try model.change { $0.workspaces[0].groups = [WindowGroup(name: "A", floating: [id])] }.get()
    try await model.execute([.conceal(id)])
    system.failMinimize = id
    model.release(id)
    try await settle(model)
    #expect(model.failedOperations == 1 && model.noticeIsFailure)
    #expect(model.state.memberIDs.isEmpty)
    let recoveryURL = directory.appendingPathComponent("recovery.json")
    #expect(try LocalFile.read(RecoveryJournal.self, from: recoveryURL).entries[id]?.minimizedByUs == true)
    system.failMinimize = nil
    model.restore()
    try await settle(model)
    #expect(system.windows[id]?.minimized == false && model.journalCount == 0)
    #expect(try LocalFile.read(RecoveryJournal.self, from: recoveryURL).entries.isEmpty)
}

@Test @MainActor func exitKeepsMissingLeaseForNextSession() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), missing = system.add(), present = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    try model.change { $0.workspaces[0].groups = [WindowGroup(name: "A", floating: [missing, present])] }.get()
    try await model.execute([.conceal(missing), .conceal(present)])
    system.windows[missing] = nil
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    await model.finish()
    let restarted = Workbench(directory: directory, controller: system)
    #expect(system.windows[present]?.minimized == false)
    #expect(Set(restarted.coordinator.journal.entries.keys) == [missing])
    #expect(restarted.coordinator.journal.entries[missing]?.minimizedByUs == true)
}

@Test @MainActor func bindToExpiredPanePreservesPriorMembershipAndLayout() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), transferring = system.add(), occupied = system.add()
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let old = WindowGroup(name: "Old", floating: [transferring])
    let target = WindowGroup(name: "Target", root: .pane(id: UUID(), tabs: [occupied], active: occupied))
    try model.change { $0.workspaces[0].groups = [old, target] }.get()
    let state = model.state
    let failed = model.bind(transferring, to: target.id, pane: UUID())
    #expect(throws: (any Error).self) { try failed.get() }
    #expect(model.state == state)
    #expect(model.noticeIsFailure)
}

@Test @MainActor func activationSaveFailureRestoresLeasesFocusAndEngagedGroups() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), original = system.add(), destination = system.add()
    system.windows[original]?.focused = true
    let model = Workbench(directory: directory, controller: system)
    model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    let previous = WindowGroup(name: "Previous", floating: [original])
    let target = Workspace(name: "Target", groups: [WindowGroup(name: "Target", floating: [destination])])
    try model.change {
        $0.workspaces[0].groups = [previous]
        $0.workspaces.append(target)
        $0.prefs.switchMode = .concentrate
    }.get()
    model.engagedGroups.insert(previous.id)
    let state = model.state, history = model.history
    try FileManager.default.moveItem(at: model.configURL, to: directory.appendingPathComponent("original"))
    try FileManager.default.createDirectory(at: model.configURL, withIntermediateDirectories: false)
    model.activate(target.id)
    try await settle(model)
    #expect(model.failedOperations == 1 && model.noticeIsFailure)
    #expect(model.state == state && model.history == history)
    #expect(model.engagedGroups == [previous.id])
    #expect(system.focusedIDs == [destination, original])
    #expect(system.windows[original]?.minimized == false && model.journalCount == 0)
}

@Test @MainActor func reconnectedFloatingMemberKeepsSavedDisplayRelativePosition() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = AppTestWindows(), old = controller.add(), replacement = controller.add()
    let model = Workbench(directory: directory, controller: controller)
    let saved = FloatingFrame(display: AppTestWindows.screen.id, relative: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4))
    try model.change {
        $0.workspaces[0].groups = [WindowGroup(name: "浮窗", floating: [old])]
        $0.identities[old] = controller.windows[old]?.identity
        $0.floatingFrames = [old: saved]
    }.get()
    controller.windows[old] = nil
    model.update(Array(controller.windows.values), permission: true, screens: [AppTestWindows.screen])
    try model.rebind(old, to: replacement).get()
    #expect(model.state.floatingFrames?[replacement] == saved)
    #expect(model.state.floatingFrames?[old] == nil)
    #expect(model.coordinator.journal.entries[replacement] == nil)
}
