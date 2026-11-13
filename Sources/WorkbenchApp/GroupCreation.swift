import AppKit
import MacWindows
import WorkbenchCore

private struct GroupCreationError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

extension Workbench {
    func createAndApplyGroup(name: String, workspace: UUID, members: [UUID], preset: LayoutPreset) async -> Result<UUID, Error> {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !terminating else {
            return .failure(GroupCreationError(reason: tr("Wait for the current operation to finish.")))
        }
        guard !readOnly else { return .failure(GroupCreationError(reason: tr("Changes could not be saved."))) }
        guard trusted else { return .failure(WindowAccessError.permission) }
        guard !title.isEmpty, !members.isEmpty, Set(members).count == members.count,
            let wi = state.workspaces.firstIndex(where: { $0.id == workspace })
        else { return .failure(GroupCreationError(reason: "请输入组名，选择工作区和窗口。")) }

        busy = true
        notice = nil
        defer { busy = false; panelManager?.sync() }
        do {
            var next = state
            let selected = Set(members)
            let switching = state.activeID != workspace
            if switching { captureFloating(in: activeWorkspace, document: &next) }
            var live = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
            // A preceding release may already have revealed a member before its AX notification is delivered.
            for id in members {
                guard let runtime = bindings[id], let expected = live[id] else { throw WindowAccessError.unavailable }
                var current = try await coordinator.read(runtime)
                guard bindings[id] == runtime, current.identity == expected.identity else { throw WindowAccessError.unavailable }
                guard !current.fullscreen, current.kind == .normal else { throw WindowAccessError.unsupported }
                current.id = id
                live[id] = current
                next.identities[id] = current.identity
            }
            for i in next.workspaces.indices {
                for j in next.workspaces[i].groups.indices {
                    for id in next.workspaces[i].groups[j].memberIDs where selected.contains(id) {
                        next.workspaces[i].groups[j].remove(id)
                    }
                }
            }
            var group = WindowGroup(name: title, floating: members)
            group.apply(preset)
            next.workspaces[wi].groups.append(group)
            next.activeID = workspace
            next.recent.removeAll { $0 == workspace }
            next.recent.insert(workspace, at: 0)
            try next.validate()

            let peers = next.workspaces[wi].groups
            let groups = switching ? peers : [group]
            let planned = plannedCommands(
                for: groups, peers: peers, mode: .arrange, preferred: members.first, document: next, live: live)
            var commands: [WindowCommand] = []
            if switching, next.prefs.switchMode == .concentrate, !planned.isEmpty {
                commands = (activeWorkspace?.groups.flatMap(\.memberIDs) ?? []).filter {
                    !selected.contains($0) && canSafelyMinimize($0)
                }.map(WindowCommand.conceal)
            }
            if !switching, let previous = activeWorkspace {
                // Only resize previously applied tiled peers whose layout actually changed.
                let affected = peers.compactMap { peer -> WindowGroup? in
                    guard engagedGroups.contains(peer.id), peer.root != nil,
                        let old = previous.groups.first(where: { $0.id == peer.id }),
                        old.root != peer.root
                            || area(for: old, among: previous.groups, document: state)
                                != area(for: peer, among: peers, document: next)
                    else { return nil }
                    var tiled = peer
                    tiled.floating = []
                    return tiled
                }
                commands += plannedCommands(
                    for: affected, peers: peers, mode: .arrange, bringForward: false, document: next, live: live)
            }
            try await execute(commands + planned) { try self.commit(next).get() }
            if switching { engagedGroups.removeAll() }
            engagedGroups.formUnion(groups.map(\.id))
            if planned.isEmpty { notice = "窗口组已保存。所选窗口当前不可排布，原有窗口状态已保留。" }
            completedOperations += 1
            return .success(group.id)
        } catch {
            failedOperations += 1
            reportFailure(error)
            return .failure(error)
        }
    }

    /// Called only by the confirmation action on an unconnected member.
    func launchApplication(for member: UUID) {
        guard !IntegrationCheck.isQA, !busy, !terminating, bindings[member] == nil, state.memberIDs.contains(member),
            let bundleID = state.identities[member]?.bundleID, !bundleID.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            Bundle(url: url)?.bundleIdentifier == bundleID
        else { reportFailure(GroupCreationError(reason: "无法找到此占位窗口对应的已安装应用。")); return }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            refresh()
            notice = "应用已在运行，请从同一应用的窗口中选择要关联的窗口。"
            return
        }
        run {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            self.refresh()
            self.notice = "应用已启动。窗口出现后，请选择要关联的窗口。"
        }
    }
}
