import AppKit
import MacWindows
import WorkbenchCore

/// Exercises the production Workbench and AX backend using a disposable external app.
@MainActor enum IntegrationCheck {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static var isQA: Bool {
        Bundle.main.bundleIdentifier == "local.windowworkbench.qa"
            || ProcessInfo.processInfo.environment["WW_INTEGRATION_CHECK"] != nil
            || CommandLine.arguments.contains("--integration-check")
    }

    // Resolve the path before Workbench looks up either of its persistent files.
    static let storageDirectory: URL? = {
        guard isQA else { return nil }
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        func invalid() -> Never {
            print("integration=failed reason=fresh_qa_bundle_and_directory_required")
            exit(64)
        }
        guard Bundle.main.bundleIdentifier == "local.windowworkbench.qa",
            CommandLine.arguments.contains("--integration-check"),
            let path = env["WW_TEST_DIRECTORY"], let executable = env["WW_INTEGRATION_CHECK"]
        else { invalid() }
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let root = bundle.deletingLastPathComponent()
        let state = root.appendingPathComponent("state", isDirectory: true)
        let fixture = root.appendingPathComponent("Fixture.app/Contents/MacOS/window-probe")
        guard root.deletingLastPathComponent().path == fm.temporaryDirectory.resolvingSymlinksInPath().path,
            root.lastPathComponent.hasPrefix("ww-integration."), bundle.lastPathComponent == "Product.app",
            (try? fm.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700,
            state.path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
            fixture.path == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path,
            (try? fm.contentsOfDirectory(atPath: state.path))?.isEmpty == true
        else { invalid() }
        return state
    }()

    static func run(model: Workbench) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WW_INTEGRATION_CHECK"], path.hasPrefix("/"),
            let directory = environment["WW_TEST_DIRECTORY"],
            URL(fileURLWithPath: directory).resolvingSymlinksInPath().path == model.directory.path,
            model.groupList.isEmpty, model.state.prefs.rules.isEmpty, model.journalCount == 0
        else {
            print("integration=failed reason=isolated_test_directory_required")
            return 1
        }
        if environment["WW_DEMO"] != nil, let workspace = model.activeWorkspace?.id {
            // Fills the dashboard for a visual check. The groups hold no windows, so nothing is moved.
            for (name, preset) in zip(["编码", "调研", "文档"], [LayoutPreset.mainAndStack, .columns, .grid]) {
                model.addGroup(name, to: workspace)
                if let id = model.activeWorkspace?.groups.last?.id { model.editGroup(id) { $0.apply(preset) } }
            }
        }
        if environment["WW_MEASURE"] == "ui" {
            // Every command publishes `busy` twice, and each publish refreshes the interface on the
            // main thread the command is waiting on. This prices one refresh without taking focus.
            do {
                try await Task.sleep(for: .seconds(2))
                let rounds = 300
                func lap(_ step: () -> Void) async throws -> (cpu: Double, wall: Double) {
                    let before = try IntegrationTiming.Usage(), start = ContinuousClock.now
                    for _ in 0..<rounds {
                        step()
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    return (try IntegrationTiming.Usage().cpuSeconds - before.cpuSeconds, IntegrationTiming.ms(since: start) / 1000)
                }
                let quiet = try await lap {}
                let active = try await lap { model.busy.toggle() }
                print(
                    String(
                        format: "ui_refresh n=%d cpu_ms_each=%.3f held_ms_each=%.3f", rounds,
                        1000 * (active.cpu - quiet.cpu) / Double(rounds), 1000 * (active.wall - quiet.wall) / Double(rounds)))
            } catch {
                print("ui_refresh=failed \(error)")
                return 1
            }
            print("integration=skipped reason=ui_refresh_only")
            return 77
        }
        if let measure = environment["WW_MEASURE"], ["1", "idle"].contains(measure) {
            do { try await IntegrationTiming.idle() } catch { print("idle=failed \(error)"); return 1 }
            // `WW_MEASURE=idle` samples the dashboard at rest without launching the focus-taking fixtures.
            if measure == "idle" { print("integration=skipped reason=idle_sample_only"); return 77 }
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
                let name = app.deletingPathExtension().lastPathComponent
                let expected = "local.windowworkbench.qa." + name
                try require(Bundle(url: app)?.bundleIdentifier == expected, "fixture bundle ID")
                let fixture = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
                try require(
                    fixture.bundleURL?.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path
                        && fixture.bundleIdentifier == expected && fixture.launchDate != nil, "fixture process identity")
                disposable.append(fixture)
            }
            try require(disposable[0].bundleIdentifier != disposable[1].bundleIdentifier, "separate app bundles required")
            model.backend.allowFixtures(disposable)
            try await exercise(model, apps: disposable)
            print("integration=passed windows=4 apps=2 isolation=fixture_pids")
            return 0
        } catch {
            print(
                "integration=failed reason=\(error) notice=\(model.notice ?? "-") last=\(String(describing: model.coordinator.lastAttempt))"
            )
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
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func pressTab(_ id: UUID, fixture: NSRunningApplication, confirmed: () -> Bool) async throws {
        guard let executable = fixture.executableURL, !fixture.isTerminated else { throw Failure("fixture helper unavailable") }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--press-test-tab", String(ProcessInfo.processInfo.processIdentifier), id.uuidString]
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        try await wait("tab AXPress or helper exit") { confirmed() || !child.isRunning }
        if !confirmed() && (child.isRunning || child.terminationStatus == 0) {
            try await wait("button changed tab", until: confirmed)
        }
        let end = ProcessInfo.processInfo.systemUptime
        try await wait("tab AXPress helper") { !child.isRunning }
        let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
        let message = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard child.terminationStatus == 0, let start = Double(message), start <= end else {
            throw Failure("tab AXPress failed (\(child.terminationStatus)): " + message)
        }
        print(String(format: "strip_axpress_to_published_focus_ms=%.1f", 1000 * (end - start)))
    }

    private static func exercise(_ model: Workbench, apps: [NSRunningApplication]) async throws {
        let firstPID = apps[0].processIdentifier, secondPID = apps[1].processIdentifier
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
                // A strip that is fading out stays ordered in for a moment but no longer takes clicks.
                $0.isVisible && !$0.ignoresMouseEvents && $0.styleMask.contains(.nonactivatingPanel) && $0.level == .floating
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
            // The scenario below verifies the opt-in minimizing path end to end.
            state.prefs.minimizesInactiveTabs = true
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

        // Default behaviour: inactive tabs stay stacked behind the active one and a switch only raises.
        model.change { $0.prefs.minimizesInactiveTabs = false }
        try await settle()
        func selectStacked(_ id: UUID, pid: pid_t) async throws {
            model.selectTab(id, group: group)
            try await settle()
            try await wait("stacked tab focus") {
                fixtures().contains { $0.id == id && $0.focused }
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && visibleStrips().count == 1
            }
            let front = try await actual(id), behind = try await actual(id == tabA ? tabB : tabA)
            try require(
                !front.minimized && !behind.minimized && behind.frame.roughlyEquals(front.frame)
                    && front.frame.roughlyEquals(selected.frame), "stacked tabs do not share the pane frame")
        }
        try await selectStacked(tabB, pid: secondPID)
        try await selectStacked(tabA, pid: firstPID)
        // Once the tabs are stacked, a switch keeps its strip in place instead of hiding and re-showing it.
        let steady = model.panelManager?.presentations
        try await selectStacked(tabB, pid: secondPID)
        try await selectStacked(tabA, pid: firstPID)
        try require(model.panelManager?.presentations == steady, "strip blinked during a stacked tab switch")

        // Moving the active window by hand detaches the strip. It returns on the settled frame.
        func strip(on frame: CGRect) -> Bool {
            visibleStrips().contains { abs($0.frame.minX - frame.minX) <= 2 && abs($0.frame.width - frame.width) <= 2 }
        }
        guard let runtime = model.bindings[tabA], let attached = steady else { throw Failure("strip state missing") }
        for (round, target) in [selected.frame.offsetBy(dx: 48, dy: 36), selected.frame].enumerated() {
            try await wait("strip attached before move") { visibleStrips().count == 1 }
            try await model.backend.setFrame(target, for: runtime)
            try await wait("strip left the moving window") { visibleStrips().isEmpty }
            try await wait("strip returned on the settled frame") {
                strip(on: target) && model.panelManager?.presentations == attached + round + 1
            }
        }
        print("integration_step=strip_follows_window passed")
        // The other window in this process occupies its own pane. Its movement must
        // leave the focused tab's strip continuously available.
        guard let sideRuntime = model.bindings[side] else { throw Failure("side window missing") }
        let priorPresentations = model.panelManager?.presentations
        for frame in [sidePane.frame.offsetBy(dx: -32, dy: 24), sidePane.frame] {
            try await model.backend.setFrame(frame, for: sideRuntime)
            try await wait("side window published") { fixtures().first { $0.id == side }?.frame.roughlyEquals(frame) == true }
            try await Task.sleep(for: StripMotion.settle + .milliseconds(100))
            try require(
                strip(on: selected.frame) && model.panelManager?.presentations == priorPresentations,
                "moving a sibling detached the focused tab strip")
        }
        print("integration_step=strip_ignores_sibling_motion passed")
        if ProcessInfo.processInfo.environment["WW_MEASURE"] == "1" {
            try await IntegrationTiming.measure(
                "tab_stacked", action: { model.selectTab($0.isMultiple(of: 2) ? tabB : tabA, group: group) },
                complete: { !model.busy },
                confirm: { index in
                    let id = index.isMultiple(of: 2) ? tabB : tabA
                    try require(model.notice == nil, "stacked tab commit")
                    try await wait("published stacked tab focus") {
                        fixtures().contains { $0.id == id && $0.focused } && visibleStrips().count == 1
                            && !fixtures().contains { [tabA, tabB].contains($0.id) && $0.minimized }
                    }
                })
        }
        // Return to the opt-in minimizing path, with the first tab selected, for the steps below.
        model.change { $0.prefs.minimizesInactiveTabs = true }
        model.selectTab(tabA, group: group)
        try await settle()
        try await wait("minimizing path restored") {
            fixtures().contains { $0.id == tabA && $0.focused } && fixtures().contains { $0.id == tabB && $0.minimized }
        }
        print("integration_step=stacked_tab_switch passed")

        if ProcessInfo.processInfo.environment["WW_MEASURE"] == "1" {
            try await IntegrationTiming.measure(
                "tab", action: { model.selectTab($0.isMultiple(of: 2) ? tabB : tabA, group: group) },
                complete: { !model.busy },
                confirm: { index in
                    let id = index.isMultiple(of: 2) ? tabB : tabA
                    try require(
                        model.notice == nil
                            && model.groupList.first(where: { $0.id == group })?.root?.panes.first(
                                where: { $0.tabs.contains(id) })?.active == id,
                        "tab commit")
                    try await wait("published tab focus") {
                        fixtures().contains { $0.id == id && $0.focused } && visibleStrips().count == 1
                    }
                })
            try await IntegrationTiming.measure(
                "workspace", action: { model.activate($0.isMultiple(of: 2) ? second : ws) },
                complete: { !model.busy },
                confirm: { index in
                    let other = index.isMultiple(of: 2)
                    try require(
                        model.notice == nil && model.state.activeID == (other ? second : ws), "workspace commit at sample \(index)")
                    let minimized: Set<UUID> = other ? [tabA, tabB, side] : [tabB, spare]
                    try await wait("published workspace visibility and focus") {
                        Set(fixtures().filter(\.minimized).map(\.id)) == minimized
                            && fixtures().contains { $0.focused && !$0.minimized }
                    }
                })
            model.change { $0.prefs.hidePrevious = false }
            for target in [second, ws] {
                model.activate(target)
                try await settle()
                try await wait("warm layout") {
                    fixtures().contains { $0.id == spare && !$0.minimized }
                        && (target == second || fixtures().contains { $0.id == tabA && !$0.minimized })
                }
            }
            try await IntegrationTiming.measure(
                "warm_arrange", action: { model.activate($0.isMultiple(of: 2) ? second : ws) },
                complete: { !model.busy },
                confirm: { index in
                    let other = index.isMultiple(of: 2)
                    try require(model.notice == nil && model.state.activeID == (other ? second : ws), "warm workspace commit")
                    let visible: Set<UUID> = other ? [spare] : [side, tabA]
                    try await wait("warm workspace focus") {
                        fixtures().contains { visible.contains($0.id) && $0.focused && !$0.minimized }
                    }
                })
            model.change { $0.prefs.hidePrevious = true }
        }
        // Workspace activation can focus the side pane. Select the tab to expose its strip again.
        model.selectTab(tabA, group: group)
        try await settle()
        try await wait("visible tab strip") { !visibleStrips().isEmpty }
        try await pressTab(tabB, fixture: apps[0]) { fixtures().contains { $0.id == tabB && $0.focused } }
        try await settle()
        model.undo()
        try await settle()
        try await wait("undo restored external tab and focus") {
            fixtures().contains { $0.id == tabA && $0.focused && !$0.minimized }
                && fixtures().contains { $0.id == tabB && $0.minimized } && visibleStrips().count == 1
        }
        print("integration_step=tab_undo passed")

        model.activate(second)
        try await settle()
        try require(model.state.activeID == second, "switch command failed before committing workspace")
        try await wait("switching workspaces") {
            Set(fixtures().filter(\.minimized).map(\.id)) == [tabA, tabB, side]
                && fixtures().contains { $0.id == spare && $0.focused } && visibleStrips().isEmpty
        }
        let workspaceFrame = try await actual(spare).frame
        guard let destination = model.activeWorkspace?.groups.first,
            let expected = model.area(for: destination, among: [destination], document: model.state)
        else { throw Failure("destination display unavailable") }
        try require(workspaceFrame.roughlyEquals(expected), "restored window did not reach the destination frame")
        // Undo is invoked through the same entry point as the dashboard button.
        model.undo()
        try await settle()
        try require(model.state.activeID == ws, "undo workspace selection")
        let afterUndo = try await actual(tabA)
        try require(!afterUndo.minimized && afterUndo.frame.roughlyEquals(selected.frame), "undo active tab frame")
        let previousWorkspace = try await actual(spare)
        try require(previousWorkspace.minimized, "undo left previous workspace visible despite hidePrevious")
        print("integration_step=workspace_undo passed")

        for target in [second, ws, second, ws] {
            model.activate(target)
            try await settle()
            try require(model.state.activeID == target, "repeat workspace commit")
            let minimized: Set<UUID> = target == second ? [tabA, tabB, side] : [tabB, spare]
            try await wait("repeat visibility") { Set(fixtures().filter(\.minimized).map(\.id)) == minimized }
        }
        model.change { state in state.workspaces.removeAll { $0.id == second } }
        try await settle()
        let released = try await actual(spare)
        try require(
            model.coordinator.journal.entries[spare] == nil && !released.minimized
                && released.frame.roughlyEquals(right[1].frame), "deleted workspace retained its fixture")
        print("integration_step=repeat_switch_and_delete passed")

        let created = try await model.createAndApplyGroup(
            name: "Fixture pair", workspace: ws, members: [spare, side], preset: .columns
        ).get()
        let saved = try LocalFile.read(WorkbenchState.self, from: model.configURL)
        try require(
            saved.workspaces.first(where: { $0.id == ws })?.groups.first(where: { $0.id == created })?.memberIDs
                == [spare, side], "created pair membership")
        let firstColumn = try await actual(spare), secondColumn = try await actual(side)
        try require(
            !firstColumn.minimized && !secondColumn.minimized && firstColumn.frame.maxX <= secondColumn.frame.minX + 2,
            "created pair did not apply its split")
        try await wait("created pair focus") { fixtures().contains { $0.id == spare && $0.focused } }
        print("integration_step=create_and_apply_pair passed")

        let stalled = apps[0]
        let pid = stalled.processIdentifier
        func stillFixture() -> Bool {
            guard !stalled.isTerminated, let now = NSRunningApplication(processIdentifier: pid) else { return false }
            return now.launchDate == stalled.launchDate && now.bundleURL == stalled.bundleURL
                && now.bundleIdentifier == "local.windowworkbench.qa.Fixture"
        }
        let beforeTimeout = model.state
        let failures = model.failedOperations
        guard stillFixture(), kill(pid, SIGSTOP) == 0 else { throw Failure("could not suspend owned fixture") }
        do {
            defer { if stillFixture() { _ = kill(pid, SIGCONT) } }
            let start = ContinuousClock.now
            model.focus(side)
            try await wait("timeout on stalled fixture") { !model.busy }
            try require(
                model.failedOperations == failures + 1 && model.state == beforeTimeout && model.notice != nil,
                "timeout did not preserve state")
            print(
                String(format: "integration_step=unresponsive_fixture passed elapsed_ms=%.1f", IntegrationTiming.ms(since: start)))
        }
        model.notice = nil
        model.focus(side)
        try await settle()
        try await wait("resumed fixture focus") { fixtures().contains { $0.id == side && $0.focused } }

        model.selectTab(tabA, group: group)
        try await settle()
        try await wait("outgoing tab has focus") { fixtures().contains { $0.id == tabA && $0.focused } }
        let beforeRelease = try await actual(tabA)
        let freeGroup = try await model.createAndApplyGroup(name: "Floating tab", workspace: ws, members: [tabA], preset: .free)
            .get()
        try await wait("floating transfer left a visible successor") {
            fixtures().contains { $0.id == tabB && !$0.minimized }
        }
        try require(try await actual(tabA).focused && model.state.memberIDs.contains(tabB), "floating transfer focus or membership")
        model.undo()
        try await settle()
        try require(!model.groupList.contains { $0.id == freeGroup }, "undo kept temporary floating group")
        model.selectTab(tabA, group: group)
        try await settle()
        try await wait("original tab visible again") { fixtures().contains { $0.id == tabA && $0.focused } }
        print("integration_step=float_active_tab passed")
        model.release(tabA)
        try await settle()
        let successor = try await actual(tabB), detached = try await actual(tabA)
        try require(
            successor.focused && !successor.minimized && successor.frame.roughlyEquals(beforeRelease.frame),
            "released tab did not hand its pane to the visible successor")
        try require(
            detached.frame.roughlyEquals(left[0].frame) && model.coordinator.journal.entries[tabA] == nil,
            "released tab did not return to its original frame")
        print("integration_step=release_active_tab passed")

        _ = try await model.createAndApplyGroup(name: "Third group", workspace: ws, members: [tabA], preset: .tabs).get()
        let newFrame = try await actual(tabA).frame
        for id in [tabB, spare, side] {
            let peer = try await actual(id)
            let overlap = peer.frame.intersection(newFrame)
            try require(!peer.minimized && (overlap.width <= 2 || overlap.height <= 2), "new group overlaps an applied peer")
        }
        print("integration_step=reflow_existing_groups passed")

        // An independent observer outlives model.finish(), which stops the app's backend.
        let observer = MacWindows(allowedApplications: apps)
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
