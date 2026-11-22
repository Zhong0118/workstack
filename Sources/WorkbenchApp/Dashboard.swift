import AppKit
import SwiftUI
import WorkbenchCore

@MainActor func d(_ key: String) -> String { tr(key, table: "Dashboard") }
@MainActor func deskCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) " + d(count == 1 ? singular : plural)
}
typealias DeskGroup = WorkbenchCore.WindowGroup

enum DeskPage: Hashable {
    case workspace(UUID), spaces, windows, templates, recent
}

struct DeskNameRequest: Identifiable {
    let id = UUID()
    let title: String
    var value: String
    let save: (String) -> Void
}

struct DeskComposeRequest: Identifiable {
    let id = UUID()
    let workspace: UUID
    let member: UUID?
}

struct DeskLaunchRequest: Identifiable {
    let id: UUID
    let bundleID: String
}

struct DeskPickerRequest: Identifiable {
    let id = UUID()
    let group: UUID
    var pane: UUID? = nil
    var rebind: UUID? = nil
}

struct Dashboard: View {
    @Environment(Workbench.self) var model
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var page: DeskPage?
    @State var selectedGroup: UUID?
    @State var editor: UUID?
    @State var member: UUID?
    @State var pane: UUID?
    @State var search = ""
    @State var inspector = true
    @State var grid = true
    @State var naming: DeskNameRequest?
    @State var picker: DeskPickerRequest?
    @State var composing: DeskComposeRequest?
    @State var launchRequest: DeskLaunchRequest?
    @State var deleting: DeskNameRequest?
    @State var didLoad = false
    /// Height the toolbar covers at the top of the detail column.
    @State var toolbarInset: CGFloat = 52
    @FocusState var searchFocused: Bool

    var workspaces: [Workspace] { model.state.workspaces }
    var allGroups: [DeskGroup] { workspaces.flatMap(\.groups) }
    var workspace: Workspace? {
        if case let .workspace(id) = page { return workspaces.first { $0.id == id } }
        return workspaces.first { $0.id == model.state.activeID } ?? workspaces.first
    }
    var group: DeskGroup? { allGroups.first { $0.id == selectedGroup } }
    var live: LiveWindow? { model.windows.first { $0.id == member } }
    var small: Bool { model.state.prefs.compact }
    var anim: Animation? {
        reduceMotion || !model.state.prefs.enableAnimations ? nil : .smooth(duration: 0.28)
    }
    /// Entering a deeper level slides in slightly. With reduced motion it only fades.
    var push: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 26)) }
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 225, max: 320)
        } detail: {
            mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .safeAreaInset(edge: .top, spacing: 0) { noticeBanner }
                .onGeometryChange(for: CGFloat.self) {
                    $0.safeAreaInsets.top
                } action: {
                    toolbarInset = $0
                }
                .inspector(isPresented: $inspector) {
                    inspectorPanel.inspectorColumnWidth(min: 240, ideal: 264, max: 380)
                }
                .toolbar { toolbarItems }
                .searchable(text: $search, placement: .toolbar, prompt: Text(d("Search workspaces, groups, windows")))
                .modifier(DeskSearchFocus(focused: $searchFocused))
                .background {
                    Button("") { focusSearch() }.keyboardShortcut("f", modifiers: .command).hidden()
                }
        }
        .frame(minWidth: inspector ? 920 : 660, minHeight: 550)
        .animation(anim, value: page)
        .animation(anim, value: editor)
        .animation(anim, value: selectedGroup)
        .animation(anim, value: grid)
        .animation(anim, value: search.isEmpty)
        .animation(anim, value: model.notice)
        .sheet(item: $naming) { req in DeskNameSheet(request: req) }
        .sheet(item: $picker) { req in DeskPicker(request: req) }
        .sheet(item: $composing) { request in
            GroupComposer(request: request) { id in
                if let group = model.groupList.first(where: { $0.id == id }) { selectGroup(group) }
            }
        }
        .alert(
            d("Open application?"), isPresented: Binding(get: { launchRequest != nil }, set: { if !$0 { launchRequest = nil } }),
            presenting: launchRequest
        ) { request in
            Button(d("Open application")) { model.launchApplication(for: request.id) }
            Button(d("Cancel"), role: .cancel) {}
        } message: { request in
            Text(d("Open this application so you can reconnect its window?") + "\n" + request.bundleID)
        }
        .alert(
            deleting?.title ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { req in
            Button(d("Delete"), role: .destructive) { req.save(req.value) }
            Button(d("Cancel"), role: .cancel) {}
        } message: { req in
            Text(req.value)
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            goHome()
        }
        .onChange(of: model.state.activeID) { _, id in
            if let id, page != .workspace(id) { navigate(.workspace(id)) }
        }
        .onChange(of: workspaces.map(\.id)) { _, ids in
            if case let .workspace(id) = page, !ids.contains(id) { goHome() }
            if page == nil { goHome() }
        }
        .onChange(of: allGroups.map(\.id)) { _, ids in
            if let editor, !ids.contains(editor) { self.editor = nil }
            if let selectedGroup, !ids.contains(selectedGroup) { self.selectedGroup = nil; member = nil; pane = nil }
        }
    }

    func goHome() {
        if let id = model.state.activeID ?? workspaces.first?.id { navigate(.workspace(id)) } else { navigate(.windows) }
    }
    func navigate(_ dest: DeskPage) {
        page = dest
        editor = nil
        selectedGroup = nil
        member = nil
        pane = nil
        search = ""
    }
    func activateWorkspace(_ id: UUID) {
        guard !model.busy else { return }
        // Show the workspace at once. Arranging its windows can take a second, and a
        // failed activation leaves its page open with the button to try again.
        navigate(.workspace(id))
        model.activate(id)
    }
    func focusSearch() {
        if #available(macOS 15, *) {
            searchFocused = true
        } else {
            NSApp.keyWindow?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first?.beginSearchInteraction()
        }
    }
    func focusGroup(_ g: DeskGroup) {
        guard !model.busy else { return }
        selectGroup(g)
        model.focusGroup(g.id)
    }
    func selectGroup(_ g: DeskGroup, edit: Bool = false) {
        if let w = workspaces.first(where: { $0.groups.contains(where: { $0.id == g.id }) }) { page = .workspace(w.id) }
        search = ""
        selectedGroup = g.id
        editor = edit ? g.id : nil
        member = nil
        pane = nil
    }
    func inspectMember(_ id: UUID) {
        member = id
        let owner = allGroups.first { $0.memberIDs.contains(id) }
        selectedGroup = owner?.id
        pane = owner?.root?.panes.first { $0.tabs.contains(id) }?.id
        inspector = true
    }
    func addWorkspace() {
        naming = DeskNameRequest(title: d("New workspace"), value: "") { name in model.addWorkspace(name) }
    }
    func addGroup(_ id: UUID, including member: UUID? = nil) {
        composing = DeskComposeRequest(workspace: id, member: member)
    }
    @ViewBuilder var mainContent: some View {
        if !search.isEmpty {
            searchResults.transition(.opacity)
        } else if let editor, let g = allGroups.first(where: { $0.id == editor }) {
            editGroupView(g).transition(push)
        } else {
            Group {
                switch page {
                case .spaces: spacesOverview
                case .windows: windowsView
                case .templates: templatesView
                case .recent: recentView
                case .workspace, nil: overview
                }
            }.transition(.opacity)
        }
    }
    @ViewBuilder var noticeBanner: some View {
        if let notice = model.notice, !notice.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: model.noticeIsFailure ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(model.noticeIsFailure ? Color.orange : Color.accentColor)
                    Text(notice).font(.callout).textSelection(.enabled)
                    Spacer()
                    iconButton("Dismiss", "xmark") { model.notice = nil }
                }.padding(10)
                Divider()
            }
            .background(.bar)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }
    @ToolbarContentBuilder var toolbarItems: some ToolbarContent {
        if editor != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    editor = nil; member = nil; pane = nil
                } label: {
                    Label(d("Back to overview"), systemImage: "chevron.left")
                }.help(d("Back to overview"))
            }
        }
        ToolbarItem(placement: .primaryAction) { DeskUndoButton() }
    }
    var sidebar: some View {
        List(
            selection: Binding(
                get: { page },
                set: { dest in
                    guard let dest, dest != page else { return }
                    if case let .workspace(id) = dest { activateWorkspace(id) } else { navigate(dest) }
                })
        ) {
            Section {
                sideItem(d("All workspaces"), "square.grid.2x2", .spaces)
                ForEach(workspaces) { w in
                    sideItem(w.name, "rectangle.stack", .workspace(w.id), active: model.state.activeID == w.id)
                        .contextMenu { workspaceMenu(w) }
                }
            } header: {
                HStack {
                    Text(d("Workspaces"))
                    Spacer()
                    iconButton("New workspace", "plus", action: addWorkspace)
                }
            }
            Section {
                sideItem(d("All windows"), "macwindow.on.rectangle", .windows)
                sideItem(d("Templates"), "square.grid.2x2", .templates)
                sideItem(d("Recent workspaces"), "clock.arrow.circlepath", .recent)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    SettingsLink {
                        Label(d("Settings"), systemImage: "gearshape")
                    }.buttonStyle(.plain)
                    Spacer()
                    Image(systemName: model.trusted ? "checkmark.shield" : "shield.slash")
                        .foregroundStyle(model.trusted ? Color.secondary : Color.orange)
                        .help(d(model.trusted ? "Accessibility enabled" : "Accessibility required"))
                }.padding(.horizontal, 15).padding(.vertical, 11)
            }
        }
    }
    func sideItem(_ name: String, _ symbol: String, _ dest: DeskPage, active: Bool = false) -> some View {
        HStack(spacing: 6) {
            Label(name, systemImage: symbol).lineLimit(1)
            Spacer(minLength: 1)
            if active {
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary).help(d("Active workspace"))
            }
        }
        .padding(.vertical, small ? 0 : 2)
        .contentShape(Rectangle())
        // Selecting a row only reports a change. Clicking the open workspace again re-applies it.
        .simultaneousGesture(
            TapGesture().onEnded {
                if page == dest, case let .workspace(id) = dest { activateWorkspace(id) }
            }
        )
        .tag(dest)
        .accessibilityValue(active ? d("Active workspace") : "")
    }
    func iconButton(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 19, height: 20).contentShape(Rectangle()) }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help(d(name)).accessibilityLabel(d(name))
    }
    @ViewBuilder func workspaceMenu(_ w: Workspace) -> some View {
        Button(d("Activate workspace")) { activateWorkspace(w.id) }.disabledWhileBusy()
        Button(d("Edit layout")) { openSpaceEditor(w) }
        Button(d("New window group")) { addGroup(w.id) }
        Divider()
        Button(d("Rename")) {
            naming = DeskNameRequest(title: d("Rename workspace"), value: w.name) { name in
                model.change { s in if let i = s.workspaces.firstIndex(where: { $0.id == w.id }) { s.workspaces[i].name = name } }
            }
        }
        Button(d("Duplicate")) { model.duplicate(w.id) }
        if let i = workspaces.firstIndex(where: { $0.id == w.id }) {
            Button(d("Move workspace up")) { model.change { $0.workspaces.swapAt(i, i - 1) } }.disabled(i == 0)
            Button(d("Move workspace down")) { model.change { $0.workspaces.swapAt(i, i + 1) } }.disabled(i + 1 >= workspaces.count)
        }
        Button(d("Delete workspace"), role: .destructive) {
            deleting = DeskNameRequest(title: d("Delete workspace") + "?", value: w.name) { _ in
                model.change { s in
                    s.workspaces.removeAll { $0.id == w.id }
                    s.recent.removeAll { $0 == w.id }
                    if s.activeID == w.id { s.activeID = s.workspaces.first?.id }
                }
            }
        }
    }
    @ViewBuilder func groupMenu(_ g: DeskGroup) -> some View {
        Button(d("Edit layout")) { selectGroup(g, edit: true) }
        Button(d("Focus group")) { focusGroup(g) }.disabledWhileBusy(or: g.memberIDs.isEmpty)
        Button(d("Apply layout")) { model.apply(g.id) }.disabledWhileBusy(or: g.memberIDs.isEmpty)
        Button(d("Add windows")) { picker = DeskPickerRequest(group: g.id) }
        Divider()
        Button(d("Rename")) {
            naming = DeskNameRequest(title: d("Rename group"), value: g.name) { name in model.editGroup(g.id) { $0.name = name } }
        }
        Button(d("Duplicate")) {
            let clone = g.emptyCopy(name: g.name + " " + d("copy"))
            model.change { s in
                if let i = s.workspaces.firstIndex(where: { $0.groups.contains(where: { $0.id == g.id }) }) {
                    s.workspaces[i].groups.append(clone)
                }
            }
        }
        Menu(d("Move to workspace")) {
            ForEach(workspaces.filter { !$0.groups.contains(where: { $0.id == g.id }) }) { w in
                Button(w.name) { moveGroup(g.id, to: w.id) }
            }
        }.disabled(workspaces.count < 2)
        Button(d("Save as template")) { model.saveTemplate(g.id) }
        Divider()
        Button(d("Delete group"), role: .destructive) {
            deleting = DeskNameRequest(title: d("Delete group") + "?", value: g.name) { _ in
                model.change { s in for i in s.workspaces.indices { s.workspaces[i].groups.removeAll { $0.id == g.id } } }
            }
        }
    }
    func moveGroup(_ id: UUID, to w: UUID) {
        let result = model.change { s in
            guard let src = s.workspaces.firstIndex(where: { $0.groups.contains(where: { $0.id == id }) }),
                let dest = s.workspaces.firstIndex(where: { $0.id == w }),
                let i = s.workspaces[src].groups.firstIndex(where: { $0.id == id })
            else { return }
            let moved = s.workspaces[src].groups.remove(at: i)
            s.workspaces[dest].groups.append(moved)
        }
        if case .success = result { navigate(.workspace(w)) }
    }
}

/// Disables its content while a command runs. A command sets `busy` twice, and reading it
/// here instead of in the dashboard's body keeps that from re-evaluating the whole dashboard.
private struct IdleOnly: ViewModifier {
    @Environment(Workbench.self) private var model
    let blocked: Bool
    func body(content: Content) -> some View { content.disabled(blocked || model.busy) }
}

extension View {
    func disabledWhileBusy(or blocked: Bool = false) -> some View { modifier(IdleOnly(blocked: blocked)) }
}

/// Undo is unavailable while a command runs, so its slot shows the progress instead of an
/// extra toolbar item that would shift its neighbours.
private struct DeskUndoButton: View {
    @Environment(Workbench.self) private var model
    var body: some View {
        Button {
            model.undo()
        } label: {
            ZStack {
                Label(d("Undo"), systemImage: "arrow.uturn.backward").opacity(model.busy ? 0 : 1)
                if model.busy { ProgressView().controlSize(.small) }
            }
        }.disabled(!model.canUndo).help(d("Undo"))
    }
}

/// Lets ⌘F reach the toolbar search field where SwiftUI exposes its focus.
private struct DeskSearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.searchFocused(focused) } else { content }
    }
}

/// The shared surface of workspace and group cards, with a light response to the pointer.
struct DeskCard: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let selected: Bool
    let compact: Bool
    let animated: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let lift = hovering && animated && !reduceMotion
        content.padding(compact ? 8 : 11)
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay(
                shape.strokeBorder(
                    selected ? Color.accentColor : Color.secondary.opacity(hovering ? 0.4 : 0.2), lineWidth: selected ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.13 : 0.04), radius: hovering ? 8 : 2, y: hovering ? 3 : 1)
            .scaleEffect(lift ? 1.012 : 1)
            .onHover { hovering = $0 }
            .animation(animated && !reduceMotion ? .snappy(duration: 0.2) : nil, value: hovering)
    }
}

private struct DeskNameSheet: View {
    let request: DeskNameRequest
    @Environment(\.dismiss) var dismiss
    @State var value: String
    init(request: DeskNameRequest) {
        self.request = request
        _value = State(initialValue: request.value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.title2.bold())
            TextField(d("Name"), text: $value).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(d("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(d("Save")) {
                    request.save(value.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 370)
    }
}
