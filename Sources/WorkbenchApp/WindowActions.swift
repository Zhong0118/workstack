import AppKit
import WorkbenchCore
import MacWindows

extension Workbench {
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !readOnly, !terminating else { return }
        busy = true
        Task {
            defer { busy = false; panelManager?.sync() }
            do { try await operation(); completedOperations += 1 } catch {
                failedOperations += 1
                notice = tr("A window did not accept the operation. Check Recovery in Settings.")
                if ProcessInfo.processInfo.environment["WW_INTEGRATION_CHECK"] != nil {
                    print("fixture command error: \(String(describing:coordinator.lastAttempt)) \(error)")
                }
            }
        }
    }

    func execute(_ commands: [WindowCommand]) async throws {
        let counts = Dictionary(grouping: raw, by: \.identity)
        let safe = Set(windows.filter { counts[$0.identity]?.count == 1 && $0.identity.permitsRecovery }.map(\.id))
        try await coordinator.perform(commands, binding: bindings, unique: safe)
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
    func area(for group: WindowGroup, among peers: [WindowGroup]) -> CGRect? {
        guard let display = displays.first(where: { $0.id == group.displayID }) ?? displays.first else { return nil }
        let rect = display.frame
        if let saved = state.groupAreas[group.id] {
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

    func commands(_ g: WindowGroup, among peers: [WindowGroup], raise: Bool) -> [WindowCommand] {
        guard let bounds = area(for: g, among: peers) else { return [] }
        var commands: [WindowCommand] = []
        for p in g.placements(in: bounds, gap: state.prefs.gap) {
            let available = p.tabs.filter { id in
                windows.contains { w in
                    w.id == id && !w.fullscreen && w.kind == .normal
                        && (!w.minimized || coordinator.journal.entries[id]?.minimizedByUs == true)
                }
            }
            guard let active = p.active.flatMap({ available.contains($0) ? $0 : nil }) ?? available.first else { continue }
            var rect = p.frame
            if p.tabs.count > 1, rect.height > 110 {
                rect.size.height -= TabPanels.height(state.prefs)
                if state.prefs.tabPosition == "top" { rect.origin.y += TabPanels.height(state.prefs) }
            }
            commands.append(.reveal(active))
            commands.append(.place(active, rect))
            for id in available where id != active {
                if state.prefs.minimizeTabs, windows.first(where: { $0.id == id })?.identity.permitsRecovery == true {
                    commands.append(.conceal(id))
                } else {
                    // Focus-only floating fallback: preserve unsupported siblings at their native positions.
                    commands.append(.reveal(id))
                }
            }
            if raise { commands.append(.raise(active)) }
        }
        for id in g.floating {
            commands.append(.reveal(id))
            if let frame = floatingFrame(id, group: g) { commands.append(.place(id, frame)) }
            if raise { commands.append(.raise(id)) }
        }
        return commands
    }
    func arrange(_ groups: [WindowGroup], focusLast: Bool) async throws {
        let cmds = groups.flatMap { commands($0, among: groups, raise: focusLast) }
        try await execute(cmds)
        engagedGroups.formUnion(groups.map(\.id))
    }
    func apply(_ group: UUID) {
        guard let (wi, gi) = indices(group, in: state) else { return }
        let ws = state.workspaces[wi]
        if state.activeID != ws.id { activate(ws.id); return }
        run {
            try await self.execute(self.commands(ws.groups[gi], among: ws.groups, raise: true))
            self.engagedGroups.insert(group)
        }
    }
    func activate(_ workspace: UUID) {
        guard !busy, let target = state.workspaces.first(where: { $0.id == workspace }) else { return }
        let previous = activeWorkspace
        var next = state
        if previous?.id != workspace { captureFloating(in: previous, document: &next) }
        run {
            var cmds: [WindowCommand] = []
            if self.trusted {
                if self.state.prefs.hidePrevious, let previous, previous.id != workspace {
                    cmds += previous.groups.flatMap(\.memberIDs).map(WindowCommand.conceal)
                }
                if self.state.prefs.switchLayouts {
                    cmds += target.groups.flatMap { self.commands($0, among: target.groups, raise: true) }
                } else {
                    cmds += target.groups.flatMap(\.memberIDs).flatMap { [WindowCommand.reveal($0), .raise($0)] }
                }
                try await self.execute(cmds)
            }
            self.engagedGroups = Set(target.groups.map(\.id))
            next.activeID = workspace
            next.recent.removeAll { $0 == workspace }
            next.recent.insert(workspace, at: 0)
            self.commit(next, remember: previous?.id != workspace)
        }
    }
    func focus(_ member: UUID) {
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
            let pane = state.workspaces[wi].groups[gi].root?.panes.first(where: { $0.tabs.contains(member) }),
            let w = windows.first(where: { $0.id == member }),
            !w.minimized || coordinator.journal.entries[member]?.minimizedByUs == true
        else { return }
        let ws = state.workspaces[wi]
        var g = ws.groups[gi]
        let previous = windows.first { $0.id == pane.active && !$0.minimized && !$0.fullscreen }
        g.activate(member)
        run {
            var cmds: [WindowCommand] = [.reveal(member)]
            if self.activeWorkspace?.id != ws.id {
                if self.state.prefs.hidePrevious {
                    cmds += (self.activeWorkspace?.groups.flatMap(\.memberIDs) ?? []).map(WindowCommand.conceal)
                }
                cmds += ws.groups.flatMap { self.commands($0.id == group ? g : $0, among: ws.groups, raise: true) }
            } else if let previous, previous.id != member {
                cmds.append(.place(member, previous.frame))
            }
            cmds.append(.raise(member))
            for id in pane.tabs where id != member {
                cmds.append(self.state.prefs.minimizeTabs ? .conceal(id) : .reveal(id))
            }
            try await self.execute(cmds)
            self.engagedGroups.insert(group)
            var next = self.state
            next.workspaces[wi].groups[gi] = g
            next.activeID = ws.id
            self.commit(next)
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
        let ids = pane.tabs.filter { bindings[$0] != nil }
        guard !ids.isEmpty else { return }
        let i = pane.active.flatMap { ids.firstIndex(of: $0) } ?? 0
        selectTab(ids[(i + direction + ids.count) % ids.count], group: g.id)
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
        change { $0.groupAreas[group] = relativeArea(region) }
        apply(group)
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
