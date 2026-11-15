import AppKit
import SwiftUI
import WorkbenchCore

@MainActor
final class Lifecycle: NSObject, NSApplicationDelegate {
    var model: Workbench?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if !IntegrationCheck.isQA { NSApp.activate(ignoringOtherApps: true) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.finish(); model.hotkey?.stop(); sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { model?.presentDashboard?() }
        return true
    }
}

@main
struct WorkstackApp: App {
    @NSApplicationDelegateAdaptor(Lifecycle.self) var lifecycle
    @State private var model = Workbench(directory: IntegrationCheck.storageDirectory)
    @Environment(\.openWindow) var openWindow
    @State private var started = false
    var body: some Scene {
        // Read here so the scene follows the preference. The binding's getter runs outside tracking.
        let showsMenuBar = !IntegrationCheck.isQA && model.state.prefs.menuBar
        Window("workstack", id: "dashboard") {
            Dashboard().environment(model).modifier(Appearance(model: model))
                .onAppear {
                    guard !started else { return }
                    started = true
                    lifecycle.model = model
                    let open = openWindow
                    model.presentDashboard = {
                        open(id: "dashboard"); NSApp.activate(ignoringOtherApps: true)
                    }
                    model.presentSwitcher = {
                        open(id: "switcher"); NSApp.activate(ignoringOtherApps: true)
                    }
                    model.start()
                    if IntegrationCheck.isQA {
                        Task { exit(await IntegrationCheck.run(model: model)) }
                    }
                }
        }.defaultSize(width: 1170, height: 755)
            // Each page carries its own heading, so the toolbar is left to search and actions.
            .windowToolbarStyle(.unified(showsTitle: false))
            .commands {
                CommandMenu(tr("Workspace")) {
                    Button(tr("Quick Switcher")) { model.openSwitcher() }
                    Button(tr("Next tab")) { model.stepTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                    Button(tr("Previous tab")) { model.stepTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                    Divider()
                    UndoCommand(model: model)
                    Button(tr("Restore original windows")) { model.restore() }
                }
            }
        Settings {
            WorkbenchSettings().environment(model).modifier(Appearance(model: model))
        }
        Window(tr("Quick Switcher"), id: "switcher") {
            QuickSwitcher().environment(model).modifier(Appearance(model: model))
        }.windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
            .defaultPosition(.center)
        MenuBarExtra(
            isInserted: Binding(
                get: { showsMenuBar },
                set: { value in
                    if !IntegrationCheck.isQA { model.change { $0.prefs.menuBar = value } }
                })
        ) {
            MenuBarContent(model: model)
        } label: {
            Label("workstack", systemImage: "rectangle.3.group")
        }

    }
}

/// Menu items are views of their own so only they follow the model, not the whole scene list.
private struct UndoCommand: View {
    let model: Workbench
    var body: some View {
        Button(tr("Undo workspace change")) { model.undo() }.keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(!model.canUndo)
    }
}

private struct MenuBarContent: View {
    let model: Workbench
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button(tr("Open dashboard")) {
            openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true)
        }
        Button(tr("Quick Switcher")) { model.openSwitcher() }
        Divider()
        ForEach(model.state.workspaces) { ws in
            Button {
                model.activate(ws.id)
            } label: {
                if ws.id == model.state.activeID { Label(ws.name, systemImage: "checkmark") } else { Text(ws.name) }
            }
        }
        Divider()
        SettingsLink { Text(tr("Settings")) }
        Button(tr("Quit workstack")) { NSApp.terminate(nil) }
    }
}

private struct Appearance: ViewModifier {
    let model: Workbench
    func body(content: Content) -> some View {
        content.preferredColorScheme(model.state.prefs.theme == "dark" ? .dark : model.state.prefs.theme == "light" ? .light : nil)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}

private struct QuickSwitcher: View {
    @Environment(Workbench.self) var model
    @Environment(\.dismissWindow) var dismissWindow
    @Environment(\.openWindow) var openWindow
    @State var query = ""
    @State var selected: String?
    @FocusState var searching: Bool
    private struct Result: Identifiable { let id, title, symbol: String; let perform: () -> Void }
    private var results: [Result] {
        let workspaces = model.state.workspaces.map { ws in
            Result(id: ws.id.uuidString, title: ws.name, symbol: "square.grid.2x2") { model.activate(ws.id) }
        }
        let groups = model.groupList.map { g in
            Result(id: g.id.uuidString, title: g.name, symbol: "rectangle.3.group") { model.focusGroup(g.id) }
        }
        let windows = model.windows.filter(model.canFocus).map { w in
            Result(id: w.id.uuidString, title: model.displayName(w.id), symbol: "macwindow") { model.focus(w.id) }
        }
        let commands = [
            Result(id: "dashboard", title: tr("Open dashboard"), symbol: "sidebar.left") { openWindow(id: "dashboard") },
            Result(id: "next", title: tr("Next tab"), symbol: "arrow.right") { model.stepTab(1) },
            Result(id: "undo", title: tr("Undo workspace change"), symbol: "arrow.uturn.backward") { model.undo() },
            Result(id: "restore", title: tr("Restore original windows"), symbol: "arrow.counterclockwise") { model.restore() },
        ]
        return (workspaces + groups + commands + windows).filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        }
    }
    private func choose(_ r: Result) { dismissWindow(id: "switcher"); r.perform() }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("Search workspaces, windows and commands"), text: $query).textFieldStyle(.plain)
                    .focused($searching).onSubmit {
                        if let item = results.first(where: { $0.id == selected }) ?? results.first { choose(item) }
                    }
            }.font(.title3).padding(18)
            Divider()
            List(selection: $selected) {
                ForEach(results) { r in
                    Label(r.title, systemImage: r.symbol).lineLimit(1).contentShape(Rectangle()).onTapGesture { choose(r) }.tag(
                        r.id)
                }
            }.listStyle(.inset)
        }.frame(width: 540, height: 350)
            .onAppear {
                query = ""; searching = true; selected = results.first?.id
            }
            .onChange(of: query) { selected = results.first?.id }
            .onKeyPress(.downArrow) {
                shift(1); return .handled
            }
            .onKeyPress(.upArrow) {
                shift(-1); return .handled
            }
            .onExitCommand { dismissWindow(id: "switcher") }
    }
    func shift(_ direction: Int) {
        let rows = results
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex(where: { $0.id == selected }) ?? 0
        selected = rows[(i + direction + rows.count) % rows.count].id
    }
}
