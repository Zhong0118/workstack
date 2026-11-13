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

struct DeskPickerRequest: Identifiable {
    let id = UUID()
    let group: UUID
    var pane: UUID? = nil
    var rebind: UUID? = nil
}

struct Dashboard: View {
    @EnvironmentObject var model: Workbench
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var page: DeskPage?
    @State var selectedSpace: UUID?
    @State var selectedGroup: UUID?
    @State var editor: UUID?
    @State var member: UUID?
    @State var pane: UUID?
    @State var search = ""
    @State var inspector = true
    @State var grid = true
    @State var naming: DeskNameRequest?
    @State var picker: DeskPickerRequest?
    @State var deleting: DeskNameRequest?
    @State var didLoad = false
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
        reduceMotion || !model.state.prefs.enableAnimations ? nil : .easeInOut(duration: 0.18)
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 225).background(.regularMaterial)
            Divider()
            VStack(spacing: 0) {
                topBar
                Divider()
                if let notice = model.notice, !notice.isEmpty {
                    HStack {
                        Image(systemName: "info.circle").foregroundStyle(.blue)
                        Text(notice).font(.callout).textSelection(.enabled)
                        Spacer()
                        iconButton("Dismiss", "xmark") { model.notice = nil }
                    }.padding(10).background(Color.accentColor.opacity(0.07))
                    Divider()
                }
                mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            if inspector {
                Divider()
                inspectorPanel.frame(width: 264)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: inspector ? 920 : 660, minHeight: 550)
        .animation(anim, value: inspector)
        .animation(anim, value: page)
        .animation(anim, value: editor)
        .animation(anim, value: selectedGroup)
        .sheet(item: $naming) { req in DeskNameSheet(request: req) }
        .sheet(item: $picker) { req in DeskPicker(request: req) }
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
            if let id { navigate(.workspace(id)) }
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
        selectedSpace = nil
        editor = nil
        selectedGroup = nil
        member = nil
        pane = nil
        search = ""
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
    func addGroup(_ id: UUID) {
        naming = DeskNameRequest(title: d("New window group"), value: "") { name in
            model.addGroup(name, to: id)
            if let g = workspaces.first(where: { $0.id == id })?.groups.last { selectGroup(g, edit: true) }
        }
    }
    @ViewBuilder var mainContent: some View {
        if !search.isEmpty {
            searchResults
        } else if let editor, let g = allGroups.first(where: { $0.id == editor }) {
            editGroupView(g)
        } else {
            switch page {
            case .spaces: spacesOverview
            case .windows: windowsView
            case .templates: templatesView
            case .recent: recentView
            case .workspace, nil: overview
            }
        }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Image(systemName: "rectangle.3.group.fill").font(.system(size: 23, weight: .semibold)).foregroundStyle(
                            .blue)
                        Text(verbatim: "WindowWorkbench").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }.padding(.vertical, 20).padding(.horizontal, 9)
                    HStack {
                        Text(d("Workspaces")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        iconButton("New workspace", "plus", action: addWorkspace)
                    }.padding(.horizontal, 9).padding(.bottom, 3)
                    sideItem(d("All workspaces"), "square.grid.2x2", .spaces)
                    ForEach(workspaces) { w in
                        sideItem(w.name, "rectangle.stack", .workspace(w.id), active: model.state.activeID == w.id)
                            .contextMenu { workspaceMenu(w) }
                    }
                    Divider().padding(.vertical, 12)
                    sideItem(d("All windows"), "macwindow.on.rectangle", .windows)
                    sideItem(d("Templates"), "square.grid.2x2", .templates)
                    sideItem(d("Recent workspaces"), "clock.arrow.circlepath", .recent)
                }.padding(.horizontal, 11)
            }
            Divider()
            HStack {
                SettingsLink {
                    Label(d("Settings"), systemImage: "gearshape")
                }.buttonStyle(.plain)
                Spacer()
                Image(systemName: model.trusted ? "checkmark.shield" : "shield.slash")
                    .foregroundStyle(model.trusted ? Color.secondary : Color.orange)
                    .help(d(model.trusted ? "Accessibility enabled" : "Accessibility required"))
            }.padding(17)
        }
    }
    func sideItem(_ name: String, _ symbol: String, _ dest: DeskPage, active: Bool = false) -> some View {
        Button {
            navigate(dest)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 19)
                Text(name).lineLimit(1)
                Spacer(minLength: 1)
                if active {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.blue).help(d("Active workspace"))
                }
            }
            .foregroundStyle(page == dest ? Color.accentColor : Color.primary)
            .padding(.horizontal, 9).padding(.vertical, small ? 6 : 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(page == dest ? Color.accentColor.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    var topBar: some View {
        HStack(spacing: 11) {
            if editor != nil {
                iconButton("Back to overview", "chevron.left") {
                    editor = nil; member = nil; pane = nil
                }
            }
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(d("Search workspaces, groups, windows"), text: $search)
                .textFieldStyle(.plain).focused($searchFocused)
                .background {
                    Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
                }
            if !search.isEmpty { iconButton("Clear search", "xmark.circle.fill") { search = "" } }
            if model.busy { ProgressView().controlSize(.small) }
            iconButton("Undo", "arrow.uturn.backward") { model.undo() }.disabled(!model.canUndo)
            Divider().frame(height: 17)
            iconButton("Inspector", "sidebar.right") { inspector.toggle() }
        }.padding(.horizontal, 19).frame(height: 49)
    }
    func iconButton(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 19, height: 20).contentShape(Rectangle()) }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help(d(name)).accessibilityLabel(d(name))
    }
    @ViewBuilder func workspaceMenu(_ w: Workspace) -> some View {
        Button(d("Activate workspace")) { model.activate(w.id) }
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
        Button(d("Apply layout")) { model.apply(g.id) }
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
        model.change { s in
            guard let src = s.workspaces.firstIndex(where: { $0.groups.contains(where: { $0.id == id }) }),
                let dest = s.workspaces.firstIndex(where: { $0.id == w }),
                let i = s.workspaces[src].groups.firstIndex(where: { $0.id == id })
            else { return }
            let moved = s.workspaces[src].groups.remove(at: i)
            s.workspaces[dest].groups.append(moved)
        }
        navigate(.workspace(w))
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
