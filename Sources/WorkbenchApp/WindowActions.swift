import AppKit
import WorkbenchCore
import MacWindows

extension Workbench {
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !terminating else {
            notice = tr("Wait for the current operation to finish.")
            noticeIsFailure = true
            return
        }
        guard !readOnly else {
            notice = tr("Configuration could not be read. Your saved files have been preserved.")
            noticeIsFailure = true
            return
        }
        busy = true
        if notice != nil { notice = nil }
        Task {
            defer { busy = false; panelManager?.sync(afterOperation: true) }
            do {
                try await operation()
                completedOperations += 1
            } catch {
                failedOperations += 1
                reportFailure(error)
            }
        }
    }

    func reportFailure(_ error: Error) {
        notice = actionMessage(error)
        noticeIsFailure = true
    }

    func actionMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription { return message }
        if let error = error as? ControlError {
            switch error {
            case .unavailable: return "窗口已关闭或状态发生变化，操作未完成。请刷新并检查窗口连接。"
            case .unexpectedFrame: return "应用未接受请求的位置或尺寸，已尝试撤回本次布局。"
            case .recoveryRequired: return "窗口身份与恢复记录不一致，请在检查器中核对连接。"
            }
        }
        return "操作未完成。请检查保存位置和窗口恢复记录。"
    }

    func missingCount(in workspace: Workspace) -> Int {
        workspace.groups.flatMap(\.memberIDs).filter { bindings[$0] == nil }.count
    }

    func canSafelyMinimize(_ member: UUID) -> Bool {
        guard let w = windows.first(where: { $0.id == member }), w.kind == .normal,
            !w.fullscreen, w.minimizable, w.identity.permitsRecovery
        else { return false }
        return raw.filter { $0.identity == w.identity }.count == 1
    }

    func execute(_ commands: [WindowCommand], commit: () throws -> Void = {}) async throws {
        guard commands.isEmpty || trusted else { throw WindowAccessError.permission }
        let counts = Dictionary(grouping: raw, by: \.identity)
        let safe = Set(windows.filter { counts[$0.identity]?.count == 1 && $0.identity.permitsRecovery }.map(\.id))
        let previous = windows.first { window in window.focused && commands.contains { $0.member == window.id } }?.id
        try await coordinator.perform(commands, binding: bindings, unique: safe, previousFocus: previous, commit: commit)
    }
    func restoreMembers(_ members: [UUID]) async throws {
        var failure: Error?
        for id in members where coordinator.journal.entries[id] != nil {
            guard let runtime = bindings[id] else { continue }
            do { try await coordinator.restore(id, runtime: runtime, safeAreas: displays.map(\.frame)) } catch { failure = error }
        }
        if let failure { throw failure }
    }
    func restore() {
        run {
            self.engagedGroups.removeAll()
            self.panelManager?.close()
            try await self.restoreMembers(Array(self.coordinator.journal.entries.keys))
            self.notice =
                self.coordinator.journal.entries.isEmpty
                ? tr("Restored managed windows.") : tr("Unmatched windows were left untouched.")
        }
    }
    func area(for group: WindowGroup, among peers: [WindowGroup], document: WorkbenchState) -> CGRect? {
        guard let display = displays.first(where: { $0.id == group.displayID }) ?? displays.first else { return nil }
        let rect = display.frame
        if let saved = document.groupAreas[group.id] {
            let proposed = CGRect(
                x: rect.minX + saved.minX * rect.width, y: rect.minY + saved.minY * rect.height,
                width: rect.width * saved.width, height: rect.height * saved.height
            ).intersection(rect)
            if proposed.width >= 100, proposed.height >= 80 { return proposed }
        }
        let same = peers.filter { other in
            other.root != nil && (displays.first(where: { $0.id == other.displayID }) ?? displays.first)?.id == display.id
        }
        guard same.count > 1, let i = same.firstIndex(where: { $0.id == group.id }) else { return rect }
        let columns = Int(ceil(sqrt(Double(same.count))))
        let rows = (same.count + columns - 1) / columns
        return CGRect(
            x: rect.minX + CGFloat(i % columns) * rect.width / CGFloat(columns),
            y: rect.minY + CGFloat(i / columns) * rect.height / CGFloat(rows),
            width: rect.width / CGFloat(columns), height: rect.height / CGFloat(rows)
        ).integral
    }

    /// Compute the whole workspace before surfacing peer windows and selecting one keyboard target.
    func plannedCommands(
        for groups: [WindowGroup], peers: [WindowGroup], mode: WorkspaceSwitchMode,
        preferred: UUID? = nil, bringForward: Bool = true, document: WorkbenchState? = nil, live supplied: [UUID: LiveWindow]? = nil
    ) -> [WindowCommand] {
        let document = document ?? state
        let live = supplied ?? Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        func available(_ id: UUID) -> Bool {
            live[id].map(canFocus) ?? false
        }
        var result = [WindowCommand]()
        var visible = [UUID]()
        for group in groups {
            guard let area = area(for: group, among: peers, document: document) else { continue }
            for pane in group.placements(in: area, gap: document.prefs.gap) {
                let tabs = pane.tabs.filter(available)
                guard let active = pane.active.flatMap({ tabs.contains($0) ? $0 : nil }) ?? tabs.first else { continue }
                visible.append(active)
                result.append(.reveal(active))
                if mode != .focus {
                    var rect = pane.frame
                    if pane.tabs.count > 1, rect.height > 110 {
                        let height = TabPanels.height(document.prefs)
                        rect.size.height -= height
                        if document.prefs.tabPosition == "top" { rect.origin.y += height }
                    }
                    result.append(.place(active, rect))
                    for id in tabs where id != active {
                        if document.prefs.minimizesInactiveTabs && canSafelyMinimize(id) {
                            result.append(.conceal(id))
                        } else {
                            // Parked behind the active tab, so selecting it later is a raise, not a move.
                            result += [.reveal(id), .stack(id, rect)]
                        }
                    }
                }
            }
            for id in group.floating where available(id) {
                visible.append(id)
                result.append(.reveal(id))
                if mode != .focus, let frame = floatingFrame(id, group: group, document: document) {
                    result.append(.place(id, frame))
                }
            }
        }
        if bringForward,
            let target = preferred.flatMap({ visible.contains($0) ? $0 : nil })
                ?? visible.first(where: { live[$0]?.focused == true }) ?? visible.first
        {
            result += visible.filter { $0 != target }.map(WindowCommand.surface)
            result.append(.raise(target))
        }
        return result
    }

    func arrange(_ groups: [WindowGroup], focusLast: Bool) async throws {
        try await execute(
            plannedCommands(for: groups, peers: activeWorkspace?.groups ?? groups, mode: .arrange, bringForward: focusLast))
        engagedGroups.formUnion(groups.map(\.id))
    }

    func apply(_ group: UUID) { enterGroup(group, mode: .arrange) }
    func focusGroup(_ group: UUID) { enterGroup(group, mode: .focus) }

    private func enterGroup(_ id: UUID, mode: WorkspaceSwitchMode) {
        guard let (wi, gi) = indices(id, in: state) else { return }
        let workspace = state.workspaces[wi]
        run { try await self.enter(workspace, groups: [workspace.groups[gi]], mode: mode) }
    }

    func activate(_ workspace: UUID) {
        guard let target = state.workspaces.first(where: { $0.id == workspace }) else { return }
        run { try await self.enter(target, groups: target.groups, mode: self.state.prefs.switchMode) }
    }

    private func enter(_ workspace: Workspace, groups: [WindowGroup], mode: WorkspaceSwitchMode) async throws {
        let previous = activeWorkspace
        var next = state
        let switching = previous?.id != workspace.id
        if switching { captureFloating(in: previous, document: &next) }
        let members = groups.flatMap(\.memberIDs)
        guard trusted || members.isEmpty else { throw WindowAccessError.permission }
        let planned = plannedCommands(for: groups, peers: workspace.groups, mode: mode)
        var cmds: [WindowCommand] = []
        // An empty/missing destination must not take away the user's current windows.
        if switching, state.prefs.switchMode == .concentrate, !planned.isEmpty {
            cmds = (previous?.groups.flatMap(\.memberIDs) ?? []).filter(canSafelyMinimize).map(WindowCommand.conceal)
        }
        next.activeID = workspace.id
        next.recent.removeAll { $0 == workspace.id }
        next.recent.insert(workspace.id, at: 0)
        try await execute(cmds + planned) { try self.commit(next, remember: switching).get() }
        if switching { engagedGroups.removeAll() }
        engagedGroups.formUnion(groups.map(\.id))
        let missing = members.filter { bindings[$0] == nil }.count
        if missing > 0 {
            notice = "有 \(missing) 个窗口未连接。布局占位已保留，可在检查器中重新关联。"
        } else if !members.isEmpty && planned.isEmpty {
            notice = "此组窗口当前不可操作，请检查最小化、全屏或显示器状态。"
        }
    }

    /// Mirrors what `focus` can deliver: dialogs, panels, full-screen windows and windows
    /// the user minimized themselves are rejected by the coordinator.
    func canFocus(_ window: LiveWindow) -> Bool {
        window.kind == .normal && !window.fullscreen
            && (!window.minimized || coordinator.journal.entries[window.id]?.minimizedByUs == true)
    }

    func focus(_ member: UUID) {
        guard bindings[member] != nil else { reportFailure(WindowAccessError.unavailable); return }
        if let g = groupList.first(where: {
            $0.root?.panes.contains(where: { $0.tabs.count > 1 && $0.tabs.contains(member) }) == true
        }) {
            selectTab(member, group: g.id)
        } else {
            run { try await self.execute([.reveal(member), .raise(member)]) }
        }
    }

    func selectTab(_ member: UUID, group: UUID) {
        guard let (wi, gi) = indices(group, in: state),
            let pane = state.workspaces[wi].groups[gi].root?.panes.first(where: { $0.tabs.contains(member) })
        else { return }
        guard let w = windows.first(where: { $0.id == member }) else {
            reportFailure(WindowAccessError.unavailable); return
        }
        guard canFocus(w) else {
            notice = "此窗口当前不可切换，请先在原应用中恢复窗口。"
            noticeIsFailure = true
            return
        }
        var ws = state.workspaces[wi]
        ws.groups[gi].activate(member)
        let switching = state.activeID != ws.id
        let previous = windows.first { $0.id == pane.active && !$0.minimized && !$0.fullscreen }
        run {
            var next = self.state
            var cmds: [WindowCommand] = []
            if switching {
                self.captureFloating(in: self.activeWorkspace, document: &next)
                if self.state.prefs.switchMode == .concentrate {
                    cmds += (self.activeWorkspace?.groups.flatMap(\.memberIDs) ?? []).filter(self.canSafelyMinimize).map(
                        WindowCommand.conceal)
                }
                cmds += self.plannedCommands(for: ws.groups, peers: ws.groups, mode: self.state.prefs.switchMode, preferred: member)
                next.recent.removeAll { $0 == ws.id }
                next.recent.insert(ws.id, at: 0)
            } else {
                cmds.append(.reveal(member))
                if let previous, previous.id != member {
                    // A window with a larger minimum size can still take keyboard focus.
                    cmds.append(.stack(member, previous.frame))
                }
                for id in pane.tabs where id != member && self.bindings[id] != nil {
                    if self.state.prefs.minimizesInactiveTabs && self.canSafelyMinimize(id) {
                        cmds.append(.conceal(id))
                    } else {
                        cmds.append(.reveal(id))
                        // Follow a pane the user dragged or resized since the layout was applied.
                        if let previous { cmds.append(.stack(id, previous.frame)) }
                    }
                }
                cmds.append(.raise(member))
            }
            next.workspaces[wi] = ws
            next.activeID = ws.id
            try await self.execute(cmds) { try self.commit(next).get() }
            if switching { self.engagedGroups = Set(ws.groups.map(\.id)) } else { self.engagedGroups.insert(group) }
        }
    }
    func stepTab(_ direction: Int) {
        guard
            let g = activeWorkspace?.groups.first(where: { group in
                windows.contains { $0.focused && group.memberIDs.contains($0.id) }
            }) ?? activeWorkspace?.groups.first(where: { $0.root?.panes.contains { $0.tabs.count > 1 } == true }),
            let pane = g.root?.panes.first(where: { pane in windows.contains { $0.focused && pane.tabs.contains($0.id) } })
                ?? g.root?.panes.first(where: { $0.tabs.count > 1 })
        else { return }
        guard !pane.tabs.isEmpty else { return }
        let eligible = Set(windows.filter(canFocus).map(\.id))
        let start = pane.active.flatMap { pane.tabs.firstIndex(of: $0) } ?? (direction > 0 ? -1 : 0)
        for step in 1...pane.tabs.count {
            let index = (start + step * direction + pane.tabs.count) % pane.tabs.count
            let candidate = pane.tabs[index]
            if eligible.contains(candidate) {
                selectTab(candidate, group: g.id)
                return
            }
        }
    }
    func finish() async {
        terminating = true
        while busy { try? await Task.sleep(for: .milliseconds(30)) }
        var saved = state
        captureFloating(in: activeWorkspace, document: &saved)
        commit(saved, remember: false)
        panelManager?.close()
        try? await restoreMembers(Array(coordinator.journal.entries.keys))
        backend.stop()
    }
}

extension Workbench {
    private func relativeArea(_ region: Int) -> CGRect {
        switch region {
        case 0: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case 1: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case 3: CGRect(x: 0.12, y: 0.12, width: 0.76, height: 0.76)
        default: CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }
    func position(_ group: UUID, region: Int) {
        if case .success = change({ $0.groupAreas[group] = relativeArea(region) }) { apply(group) }
    }
    func tile(_ member: UUID, region: Int) {
        guard let w = windows.first(where: { $0.id == member }),
            let display = displays.first(where: {
                $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY))
            }) ?? displays.first
        else { return }
        let r = relativeArea(region), d = display.frame
        let frame = CGRect(
            x: d.minX + r.minX * d.width, y: d.minY + r.minY * d.height, width: r.width * d.width, height: r.height * d.height
        ).integral
        run { try await self.execute([.place(member, frame), .raise(member)]) }
    }
}
