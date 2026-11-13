import AppKit
import Combine
import MacWindows
import WorkbenchCore

private struct EditError: LocalizedError {
    var errorDescription: String?
}

@MainActor
final class Workbench: ObservableObject {
    @Published private(set) var state: WorkbenchState
    @Published private(set) var windows: [LiveWindow] = []
    @Published private(set) var displays: [DisplayArea] = []
    @Published private(set) var trusted = false
    @Published var busy = false
    @Published var noticeIsFailure = false
    @Published var notice: String? {
        didSet { noticeIsFailure = false }
    }
    let backend: MacWindows
    let coordinator: WindowCoordinator
    let directory: URL
    var bindings: [UUID: UUID] = [:]
    var raw: [LiveWindow] = []
    var history: [WorkbenchState] = []
    var completedOperations = 0
    var failedOperations = 0
    var readOnly = false
    var terminating = false
    var panelManager: TabPanels?
    var hotkey: GlobalShortcut?
    var engagedGroups = Set<UUID>()
    var presentSwitcher: (() -> Void)?
    var presentDashboard: (() -> Void)?
    private let icons = NSCache<NSString, NSImage>()
    var canUndo: Bool { !history.isEmpty && !busy }
    var journalCount: Int { coordinator.journal.entries.count }
    var configURL: URL { directory.appendingPathComponent("workspaces.json") }
    var groupList: [WindowGroup] { state.workspaces.flatMap(\.groups) }
    var activeWorkspace: Workspace? { state.workspaces.first { $0.id == state.activeID } }

    init(directory: URL? = nil, controller: (any WindowControl)? = nil) {
        backend = MacWindows(allowedApplications: IntegrationCheck.isQA ? [] : nil)
        let folder =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowWorkbench", isDirectory: true)
        self.directory = folder
        var config = WorkbenchState()
        var journal = RecoveryJournal()
        let configPath = folder.appendingPathComponent("workspaces.json")
        let journalPath = folder.appendingPathComponent("recovery.json")
        do {
            if FileManager.default.fileExists(atPath: configPath.path) {
                config = try LocalFile.read(WorkbenchState.self, from: configPath)
                try config.validate()
                // The original English release saved its untouched starter workspace on exit.
                if config.workspaces.count == 1, config.workspaces[0].name == "My Workspace",
                    config.workspaces[0].groups.isEmpty, config.recent.isEmpty, config.templates.isEmpty
                {
                    config.workspaces[0].name = tr("My Workspace")
                }
            } else {
                let initial = Workspace(name: tr("My Workspace"))
                config.workspaces = [initial]
                config.activeID = initial.id
            }
            if FileManager.default.fileExists(atPath: journalPath.path) {
                journal = try LocalFile.read(RecoveryJournal.self, from: journalPath)
                guard journal.version == 1 else { throw StorageError.unsupportedVersion }
            }
        } catch {
            readOnly = true
            config = WorkbenchState()
            notice = tr("Configuration could not be read. Your saved files have been preserved.")
        }
        state = config
        coordinator = WindowCoordinator(controller: controller ?? backend, journal: journal) {
            try LocalFile.write($0, to: journalPath)
        }
        if !journal.entries.isEmpty { notice = tr("A previous session has windows to restore. Review Recovery in Settings.") }
    }

    func start() {
        panelManager = TabPanels(model: self)
        if !IntegrationCheck.isQA {
            hotkey = GlobalShortcut { [weak self] action in
                switch action {
                case .switcher: self?.openSwitcher()
                case .nextTab: self?.stepTab(1)
                case .previousTab: self?.stepTab(-1)
                case .undo: self?.undo()
                }
            }
        }
        configureShortcut()
        backend.onChange = { [weak self] snapshot in self?.update(snapshot) }
        authorizeRecovery()
        backend.start()
        refresh()
    }
    func refresh() {
        trusted = backend.trusted
        displays = MacDisplay.all
        backend.refresh()
    }
    func requestPermission() { backend.requestPermission(); refresh() }
    func openSwitcher() {
        presentSwitcher?()
    }
    func configureShortcut() {
        guard let hotkey else { return }
        if !hotkey.configure(state.prefs) { notice = tr("Shortcut is already in use. Choose another in Settings.") }
    }

    private func authorizeRecovery() {
        backend.authorizeRecovery(coordinator.journal.entries.values.filter(\.minimizedByUs).map(\.identity))
    }
    func update(_ snapshot: [LiveWindow], permission: Bool? = nil, screens: [DisplayArea]? = nil) {
        authorizeRecovery()
        let granted = permission ?? backend.trusted
        if trusted != granted { trusted = granted }
        let nextDisplays = screens ?? MacDisplay.all
        let displayChanged = !displays.isEmpty && displays != nextDisplays
        if displays != nextDisplays { displays = nextDisplays }
        raw = snapshot
        var known = coordinator.journal.entries.mapValues(\.identity)
        known.merge(state.identities) { first, _ in first }
        let candidates = Dictionary(grouping: snapshot.filter { $0.identity.permitsRecovery }, by: \.identity)
        let logicals = Dictionary(grouping: known.keys, by: { known[$0]! })
        var used = Set<UUID>()
        var lookup: [UUID: UUID] = [:]
        let previousLogical = Dictionary(uniqueKeysWithValues: bindings.map { ($1, $0) })
        for w in snapshot {
            let same = previousLogical[w.id]
            let matches = logicals[w.identity] ?? []
            let safe = w.identity.permitsRecovery && candidates[w.identity]?.count == 1 && matches.count == 1
            let logical = same ?? (safe ? matches[0] : w.id)
            if used.insert(logical).inserted { lookup[logical] = w.id }
        }
        bindings = lookup
        let reverse = Dictionary(uniqueKeysWithValues: lookup.map { ($1, $0) })
        let remapped = snapshot.compactMap { item -> LiveWindow? in
            guard let id = reverse[item.id], !state.prefs.excludedApps.contains(item.bundleID),
                !state.prefs.excludedWindows.contains(id)
            else { return nil }
            var w = item
            w.id = id
            return w
        }
        if !busy {
            let wasMinimized = Set(windows.filter(\.minimized).map(\.id))
            for w in remapped where !w.minimized && wasMinimized.contains(w.id) {
                do { try coordinator.observeVisible(w.id, identity: w.identity) } catch {
                    notice = tr("Could not save recovery information.")
                }
            }
        }
        if windows != remapped { windows = remapped }
        if !busy, !readOnly, !terminating {
            assignRules()
            if let focused = windows.first(where: { $0.focused && !$0.minimized }),
                let group = activeWorkspace?.groups.first(where: { $0.memberIDs.contains(focused.id) }),
                let pane = group.root?.panes.first(where: { $0.tabs.contains(focused.id) }), pane.active != focused.id
            {
                modifyGroup(group.id, remember: false) { $0.activate(focused.id) }
            }
            if displayChanged, let ws = activeWorkspace {
                let active = ws.groups.filter { engagedGroups.contains($0.id) }
                if !active.isEmpty { run { try await self.arrange(active, focusLast: false) } }
            }
        }
        panelManager?.sync()
    }

    func assignRules() {
        guard !state.prefs.rules.isEmpty else { return }
        var result = state
        var assigned = Set(state.memberIDs)
        for w in windows where !assigned.contains(w.id) && w.kind == .normal && !w.fullscreen {
            guard
                let rule = state.prefs.rules.first(where: {
                    $0.bundleID == w.bundleID
                        && ($0.titleContains.isEmpty || w.title.localizedCaseInsensitiveContains($0.titleContains))
                }), let (wi, gi) = indices(rule.group, in: result)
            else { continue }
            result.workspaces[wi].groups[gi].insert(w.id)
            result.identities[w.id] = w.identity
            assigned.insert(w.id)
        }
        if result != state { commit(result, remember: false) }
    }

    func icon(_ member: UUID) -> NSImage? {
        guard let bundle = windows.first(where: { $0.id == member })?.bundleID ?? state.identities[member]?.bundleID,
            !bundle.isEmpty
        else { return nil }
        if let cached = icons.object(forKey: bundle as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons.countLimit = 120
        icons.setObject(icon, forKey: bundle as NSString)
        return icon
    }
    func displayName(_ id: UUID) -> String {
        if let w = windows.first(where: { $0.id == id }) { return w.title.isEmpty ? w.appName : w.title }
        return state.identities[id]?.bundleID ?? tr("Unavailable window")
    }
    func indices(_ id: UUID, in document: WorkbenchState) -> (Int, Int)? {
        for (wi, w) in document.workspaces.enumerated() {
            if let gi = w.groups.firstIndex(where: { $0.id == id }) { return (wi, gi) }
        }
        return nil
    }
    private func rejected(_ message: String) -> Result<Void, Error> {
        notice = message
        noticeIsFailure = true
        return .failure(EditError(errorDescription: message))
    }

    @discardableResult
    func commit(_ proposed: WorkbenchState, remember: Bool = true) -> Result<Void, Error> {
        guard !readOnly else { return rejected(tr("Configuration could not be read. Your saved files have been preserved.")) }
        guard proposed != state else { return .success(()) }
        var next = proposed
        if !next.workspaces.contains(where: { $0.id == next.activeID }) { next.activeID = next.workspaces.first?.id }
        next.recent.removeAll { !next.workspaces.map(\.id).contains($0) }
        let members = Set(next.memberIDs).union(next.prefs.excludedWindows)
        next.identities = next.identities.filter { members.contains($0.key) }
        next.floatingFrames = next.floatingFrames?.filter { members.contains($0.key) }
        let groups = Set(next.workspaces.flatMap { $0.groups.map(\.id) })
        next.prefs.rules.removeAll { !groups.contains($0.group) }
        next.groupAreas = next.groupAreas.filter { groups.contains($0.key) }
        let shortcutsChanged =
            state.prefs.shortcutKey != next.prefs.shortcutKey || state.prefs.shortcutModifiers != next.prefs.shortcutModifiers
            || state.prefs.additionalShortcuts != next.prefs.additionalShortcuts
            || state.prefs.shortcutsEnabled != next.prefs.shortcutsEnabled
        do {
            try next.validate()
            if shortcutsChanged, let hotkey, !hotkey.configure(next.prefs) {
                _ = hotkey.configure(state.prefs)
                return rejected(tr("Shortcut is already in use. Choose another in Settings."))
            }
            try LocalFile.write(next, to: configURL)
        } catch {
            if shortcutsChanged { _ = hotkey?.configure(state.prefs) }
            return rejected(tr("Changes could not be saved."))
        }
        let previous = state
        if remember { history.append(previous); if history.count > 40 { history.removeFirst() } }
        state = next
        engagedGroups.formIntersection(groups)
        panelManager?.sync()
        return .success(())
    }

    @discardableResult
    func change(_ edit: (inout WorkbenchState) -> Void) -> Result<Void, Error> {
        guard !busy, !terminating else { return rejected(tr("Wait for the current operation to finish.")) }
        var next = state
        edit(&next)
        let removed = Set(state.memberIDs).subtracting(next.memberIDs)
        let result = commit(next)
        if case .success = result {
            let leased = removed.filter { coordinator.journal.entries[$0] != nil && bindings[$0] != nil }
            if !leased.isEmpty { run { try await self.restoreMembers(Array(leased)) } }
        }
        return result
    }
    func modifyGroup(_ id: UUID, remember: Bool, _ edit: (inout WindowGroup) -> Void) {
        guard let (wi, gi) = indices(id, in: state) else { return }
        var next = state
        edit(&next.workspaces[wi].groups[gi])
        commit(next, remember: remember)
    }
    func editGroup(_ id: UUID, _ edit: (inout WindowGroup) -> Void) {
        change { next in
            if let (wi, gi) = indices(id, in: next) { edit(&next.workspaces[wi].groups[gi]) }
        }
    }
    func addWorkspace(_ name: String) {
        let w = Workspace(name: name)
        if case .success = change({ $0.workspaces.append(w) }) { activate(w.id) }
    }
    func addGroup(_ name: String, to workspace: UUID) {
        change { next in
            guard let i = next.workspaces.firstIndex(where: { $0.id == workspace }) else { return }
            next.workspaces[i].groups.append(WindowGroup(name: name))
        }
    }
    func duplicate(_ workspace: UUID) {
        guard let w = state.workspaces.first(where: { $0.id == workspace }) else { return }
        change { $0.workspaces.append(w.emptyCopy(name: w.name + " " + tr("Copy"))) }
    }
    func saveTemplate(_ group: UUID) {
        guard let g = groupList.first(where: { $0.id == group }) else { return }
        change { $0.templates.append(g.emptyCopy(name: g.name)) }
    }
    func useTemplate(_ template: UUID, workspace: UUID) {
        guard let g = state.templates.first(where: { $0.id == template }),
            let wi = state.workspaces.firstIndex(where: { $0.id == workspace })
        else { return }
        change { $0.workspaces[wi].groups.append(g.emptyCopy(name: g.name)) }
    }
    @discardableResult
    func bind(_ window: UUID, to group: UUID, pane: UUID? = nil, edge: LayoutEdge = .center) -> Result<Void, Error> {
        guard let live = windows.first(where: { $0.id == window }), live.kind == .normal, !live.fullscreen,
            let (wi, gi) = indices(group, in: state)
        else { return rejected(tr("Unavailable window")) }
        if let pane, state.workspaces[wi].groups[gi].root?.panes.contains(where: { $0.id == pane }) != true {
            return rejected(tr("Changes could not be saved."))
        }
        return change { next in
            for i in next.workspaces.indices {
                for j in next.workspaces[i].groups.indices where !(i == wi && j == gi) {
                    next.workspaces[i].groups[j].remove(window)
                }
            }
            next.workspaces[wi].groups[gi].insert(window, at: pane, edge: edge)
            next.identities[window] = live.identity
        }
    }
    func combine(_ first: UUID, _ second: UUID, in workspace: UUID) {
        guard first != second, let wi = state.workspaces.firstIndex(where: { $0.id == workspace }),
            let a = windows.first(where: { $0.id == first && $0.kind == .normal && !$0.fullscreen }),
            let b = windows.first(where: { $0.id == second && $0.kind == .normal && !$0.fullscreen })
        else { return }
        if let existing = groupList.first(where: { $0.memberIDs.contains(second) }) {
            bind(first, to: existing.id, pane: existing.root?.panes.first(where: { $0.tabs.contains(second) })?.id)
            return
        }
        change { next in
            for i in next.workspaces.indices {
                for j in next.workspaces[i].groups.indices { next.workspaces[i].groups[j].remove(first) }
            }
            var group = WindowGroup(name: b.appName == a.appName ? a.appName : b.appName + " + " + a.appName)
            group.insert(second)
            group.insert(first)
            next.workspaces[wi].groups.append(group)
            next.identities[first] = a.identity
            next.identities[second] = b.identity
        }
    }
    func release(_ member: UUID) {
        change { next in
            for wi in next.workspaces.indices {
                for gi in next.workspaces[wi].groups.indices { next.workspaces[wi].groups[gi].remove(member) }
            }
        }
    }
    func exclude(_ member: UUID, app: Bool) {
        guard let live = windows.first(where: { $0.id == member }) else { return }
        let ids = app ? windows.filter { $0.bundleID == live.bundleID }.map(\.id) : [member]
        let result = change { next in
            if app {
                next.prefs.excludedApps.insert(live.bundleID)
            } else {
                next.prefs.excludedWindows.insert(member); next.identities[member] = live.identity
            }
            for wi in next.workspaces.indices {
                for gi in next.workspaces[wi].groups.indices {
                    for id in ids { next.workspaces[wi].groups[gi].remove(id) }
                }
            }
        }
        if case .success = result { refresh() }
    }

    @discardableResult
    func rebind(_ member: UUID, to live: UUID) -> Result<Void, Error> {
        guard !busy else { return rejected(tr("Wait for the current operation to finish.")) }
        guard state.memberIDs.contains(member), bindings[member] == nil, bindings[live] != nil, !state.memberIDs.contains(live),
            let w = windows.first(where: { $0.id == live }), w.bundleID == state.identities[member]?.bundleID,
            w.kind == .normal, !w.fullscreen, coordinator.journal.entries[live] == nil
        else { return rejected(tr("Unavailable window")) }
        // Rebinding assigns layout membership only. A new window must never inherit an old restoration lease.
        return change { next in
            for wi in next.workspaces.indices {
                for gi in next.workspaces[wi].groups.indices {
                    var g = next.workspaces[wi].groups[gi]
                    guard g.memberIDs.contains(member) else { continue }
                    if let p = g.root?.panes.first(where: { $0.tabs.contains(member) }) {
                        g.insert(live, at: p.id)
                        if let index = p.tabs.firstIndex(of: member) { g.reorder(live, to: index) }
                        if let active = p.active, active != member { g.activate(active) }
                    } else {
                        g.setFloating(live, true)
                    }
                    g.remove(member)
                    next.workspaces[wi].groups[gi] = g
                }
            }
            if let savedFrame = next.floatingFrames?.removeValue(forKey: member) {
                next.floatingFrames?[live] = savedFrame
            }
            next.identities[live] = w.identity
        }
    }
    func undo() {
        guard canUndo, let previous = history.last else { return }
        let removed = Set(state.memberIDs).subtracting(previous.memberIDs)
        let departed = activeWorkspace
        let target = previous.workspaces.first { $0.id == previous.activeID }
        let switching = departed?.id != target?.id
        let oldPanes = target?.groups.flatMap { $0.root?.panes ?? [] } ?? []
        let currentPanes = departed?.groups.flatMap { $0.root?.panes ?? [] } ?? []
        let preferred = oldPanes.first { pane in
            currentPanes.contains { $0.id == pane.id && $0.active != pane.active }
        }?.active
        run {
            var cmds = removed.compactMap { id -> WindowCommand? in
                guard self.bindings[id] != nil, self.coordinator.journal.entries[id] != nil else { return nil }
                return .restore(id, safeAreas: self.displays.map(\.frame))
            }
            var appliedGroups: [WindowGroup] = []
            if let target {
                let layoutChanged =
                    departed?.groups != target.groups || previous.groupAreas != self.state.groupAreas
                    || previous.floatingFrames != self.state.floatingFrames || previous.prefs.gap != self.state.prefs.gap
                if switching || layoutChanged {
                    let mode = switching ? previous.prefs.switchMode : .arrange
                    let planned = self.plannedCommands(
                        for: target.groups, peers: target.groups, mode: mode,
                        preferred: preferred, document: previous)
                    if switching, mode == .concentrate, !planned.isEmpty, let departed {
                        let staying = Set(target.groups.flatMap(\.memberIDs))
                        cmds += departed.groups.flatMap(\.memberIDs).filter {
                            !staying.contains($0) && !removed.contains($0) && self.canSafelyMinimize($0)
                        }.map(WindowCommand.conceal)
                    }
                    cmds += planned
                    appliedGroups = target.groups
                }
            }
            try await self.execute(cmds) { try self.commit(previous, remember: false).get() }
            self.history.removeLast()
            if switching { self.engagedGroups.removeAll() }
            self.engagedGroups.formUnion(appliedGroups.map(\.id))
        }
    }
}
