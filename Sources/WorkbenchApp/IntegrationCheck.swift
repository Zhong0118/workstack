import AppKit
import MacWindows
import WorkbenchCore

/// Exercises the production Workbench and AX backend using a disposable external app.
@MainActor enum IntegrationCheck {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func run(model: Workbench) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WW_INTEGRATION_CHECK"], path.hasPrefix("/"),
            let directory = environment["WW_TEST_DIRECTORY"],
            URL(fileURLWithPath: directory).standardizedFileURL == model.directory.standardizedFileURL,
            model.groupList.isEmpty, model.state.prefs.rules.isEmpty, model.journalCount == 0
        else {
            print("integration=failed reason=isolated_test_directory_required")
            return 1
        }
        guard model.backend.trusted else {
            print("integration=skipped reason=accessibility_permission")
            return 77
        }

        let executable = URL(fileURLWithPath: path)
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app" else { print("integration=failed reason=fixture_bundle_required"); return 1 }
        var disposable = [NSRunningApplication]()
        defer { for fixture in disposable { fixture.terminate() } }
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--fixture", "2"]
            let peer = bundle.deletingLastPathComponent().appendingPathComponent("Peer.app")
            for app in [bundle, peer] {
                let fixture = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
                disposable.append(fixture)
            }
            try require(disposable[0].bundleIdentifier != disposable[1].bundleIdentifier, "separate app bundles required")
            try await exercise(model, first: disposable[0].processIdentifier, second: disposable[1].processIdentifier)
            print("integration=passed windows=4 apps=2 isolation=fixture_pids")
            return 0
        } catch {
            print("integration=failed reason=\(error) notice=\(model.notice ?? "-")")
            if !model.terminating { await model.finish() }
            return 1
        }
    }

    private static func require(_ condition: Bool, _ detail: String) throws {
        if !condition { throw Failure(detail) }
    }

    private static func wait(_ detail: String, until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(14))
        while !condition() {
            guard clock.now < deadline else { throw Failure("timed out: " + detail) }
            try await Task.sleep(for: .milliseconds(75))
        }
    }

    private static func exercise(_ model: Workbench, first firstPID: pid_t, second secondPID: pid_t) async throws {
        let pids: Set<pid_t> = [firstPID, secondPID]
        func fixtures() -> [LiveWindow] { model.windows.filter { pids.contains($0.identity.pid) } }
        func settle(line: Int = #line) async throws {
            try await wait("command completion") { !model.busy }
            if let notice = model.notice { throw Failure("command at line \(line): " + notice) }
        }
        func actual(_ id: UUID) async throws -> LiveWindow {
            guard let runtime = model.bindings[id] else { throw Failure("fixture binding missing") }
            let w = try await model.backend.read(runtime)
            try require(pids.contains(w.identity.pid), "fixture PID mismatch")
            return w
        }
        func visibleStrips() -> [NSPanel] {
            NSApp.windows.compactMap { $0 as? NSPanel }.filter {
                $0.isVisible && $0.styleMask.contains(.nonactivatingPanel) && $0.level == .floating
            }
        }
        try await wait("four fixture windows") { fixtures().count == 4 }
        for w in fixtures() where !w.identity.permitsRecovery {
            throw Failure(
                "fixture identity lacks bundle=\(!w.bundleID.isEmpty) launch=\(w.identity.launched != nil) identifier=\(w.identity.identifier != nil)"
            )
        }
        let original = fixtures().sorted { ($0.identity.identifier ?? "") < ($1.identity.identifier ?? "") }
        let ids = original.map(\.id)
        let left = original.filter { $0.identity.pid == firstPID }, right = original.filter { $0.identity.pid == secondPID }
        try require(left.count == 2 && right.count == 2, "two windows per app required")
        let tabA = left[0].id, tabB = right[0].id, side = left[1].id, spare = right[1].id
        print("fixture_targets first_tab=\(tabA) second_tab=\(tabB) first_side=\(side) second_workspace=\(spare)")
        guard let ws = model.activeWorkspace?.id else { throw Failure("initial workspace missing") }
        model.addGroup("Source group", to: ws)
        guard let group = model.activeWorkspace?.groups.first?.id else { throw Failure("group missing") }
        model.addWorkspace("Second workspace")
        try await settle()
        guard let second = model.activeWorkspace?.id, second != ws else { throw Failure("second workspace missing") }
        model.addGroup("Rebound group", to: second)
        guard let rebound = model.activeWorkspace?.groups.first?.id else { throw Failure("rebind group missing") }

        // Seed a saved membership whose original process is gone.
        let missing = UUID()
        var stale = right[1].identity
        stale.pid = -1
        model.change { state in
            let i = state.workspaces.firstIndex { $0.id == second }!
            state.workspaces[i].groups[0].insert(missing)
            state.identities[missing] = stale
            state.prefs.hidePrevious = true
        }
        model.rebind(missing, to: spare)
        try await settle()
        try require(model.groupList.first(where: { $0.id == rebound })?.memberIDs == [spare], "rebind membership")
        try require(model.state.identities[missing] == nil, "obsolete identity after rebind")

        model.bind(tabA, to: group)
        model.bind(tabB, to: group)
        guard let pane = model.groupList.first(where: { $0.id == group })?.root?.id else { throw Failure("tab pane missing") }
        model.bind(side, to: group, pane: pane, edge: .right)
        let stored = try LocalFile.read(WorkbenchState.self, from: model.configURL)
        try stored.validate()
        try require(stored == model.state && Set(stored.memberIDs) == Set(ids), "persisted workspace mismatch")
        print("integration_step=storage_rebind passed")

        model.activate(ws)
        try await settle()
        try require(model.state.activeID == ws && model.journalCount > 0, "activation")
        try await wait("workspace and tab minimization") {
            Set(fixtures().filter(\.minimized).map(\.id)) == [tabA, spare]
        }
        let initialTab = try await actual(tabB)
        let sidePane = try await actual(side)
        try require(initialTab.frame.maxX <= sidePane.frame.minX + 1, "split panes overlapped")
        model.selectTab(tabA, group: group)
        try await settle()
        try await wait("focused tab and external strip") {
            fixtures().contains { $0.id == tabA && $0.focused } && visibleStrips().count == 1
        }
        let selected = try await actual(tabA)
        let inactive = try await actual(tabB)
        try require(selected.frame.roughlyEquals(initialTab.frame) && inactive.minimized, "selected tab frame or minimization")
        try await wait("strip matches focused tab frame") {
            visibleStrips().contains { !$0.canBecomeKey && abs($0.frame.width - selected.frame.width) <= 2 }
        }
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == firstPID, "tab did not focus first app")
        model.selectTab(tabB, group: group)
        try await settle()
        try await wait("tab selected in second app") {
            fixtures().contains { $0.id == tabB && $0.focused }
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == secondPID
        }
        model.selectTab(tabA, group: group)
        try await settle()
        try await wait("tab selected back in first app") {
            fixtures().contains { $0.id == tabA && $0.focused }
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == firstPID
        }
        print("integration_step=cross_app_split_tab_panel passed")

        model.activate(second)
        try await settle()
        try require(model.state.activeID == second, "switch command failed before committing workspace")
        try await wait("switching workspaces") {
            Set(fixtures().filter(\.minimized).map(\.id)) == [tabA, tabB, side]
                && fixtures().contains { $0.id == spare && $0.focused } && visibleStrips().isEmpty
        }
        // Undo is invoked through the same entry point as the dashboard button.
        model.undo()
        try await settle()
        try require(model.state.activeID == ws, "undo workspace selection")
        let afterUndo = try await actual(tabA)
        try require(!afterUndo.minimized && afterUndo.frame.roughlyEquals(selected.frame), "undo active tab frame")
        let previousWorkspace = try await actual(spare)
        try require(previousWorkspace.minimized, "undo left previous workspace visible despite hidePrevious")
        print("integration_step=workspace_undo passed")

        // An independent observer outlives model.finish(), which stops the app's backend.
        let observer = MacWindows()
        var observed = [LiveWindow]()
        observer.onChange = { observed = $0.filter { pids.contains($0.identity.pid) } }
        observer.start()
        defer { observer.stop() }
        try await wait("recovery observer discovery") { observed.count == 4 }
        await model.finish()
        try require(model.journalCount == 0 && visibleStrips().isEmpty, "exit did not clear leases and strips")
        for before in original {
            guard let same = observed.first(where: { $0.identity == before.identity }) else { throw Failure("identity lost") }
            let after = try await observer.read(same.id)
            try require(
                after.minimized == before.minimized && after.frame.roughlyEquals(before.frame),
                "exit restore mismatch for \(before.identity.identifier ?? "unknown")")
        }
        let journal = try LocalFile.read(RecoveryJournal.self, from: model.directory.appendingPathComponent("recovery.json"))
        try require(journal.entries.isEmpty, "persisted journal still contains a lease")
        print("integration_step=shutdown_restoration passed")
    }
}
