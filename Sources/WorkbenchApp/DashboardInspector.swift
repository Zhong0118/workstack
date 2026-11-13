import SwiftUI
import WorkbenchCore

extension Dashboard {
    var inspectedWorkspace: Workspace? {
        if case .workspace = page { return workspace }
        if page == .spaces { return workspaces.first(where: { $0.id == selectedSpace }) }
        return nil
    }
    var inspectorPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(d("Inspector")).font(.headline)
                Spacer()
                iconButton("Close inspector", "xmark") { inspector = false }
            }.padding(.horizontal, 17).frame(height: 49)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if let member {
                        windowInspector(member)
                    } else if let g = group {
                        groupInspector(g)
                    } else if let w = inspectedWorkspace {
                        inspectorTitle(w.name, icon: "rectangle.stack", type: "Workspace")
                        Divider()
                        info("Window groups", String(w.groups.count))
                        info("Windows", String(w.groups.flatMap(\.memberIDs).count))
                        if model.state.activeID == w.id {
                            Label(d("Active workspace"), systemImage: "checkmark.circle").foregroundStyle(.blue)
                        } else {
                            Button(d("Activate workspace")) { model.activate(w.id) }
                        }
                        Divider()
                        Button {
                            addGroup(w.id)
                        } label: {
                            Label(d("New window group"), systemImage: "plus")
                        }
                        Menu(d("Workspace actions")) { workspaceMenu(w) }
                    } else {
                        inspectorTitle(d("Window details"), icon: "sidebar.right", type: "Inspector")
                        Text(d("Select a window or group to inspect its properties.")).foregroundStyle(.secondary)
                    }
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Button {
                model.restore()
            } label: {
                Label(d("Restore managed windows"), systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderless).padding(15)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    func inspectorTitle(_ title: String, icon: String, type: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 23)).foregroundStyle(.blue)
            Text(d(type)).font(.caption).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold)).textSelection(.enabled)
        }
    }
    func info(_ key: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        } label: {
            Text(d(key)).foregroundStyle(.secondary)
        }.font(.callout)
    }
    @ViewBuilder func groupInspector(_ g: DeskGroup) -> some View {
        inspectorTitle(g.name, icon: "rectangle.3.group", type: "Window group")
        Divider()
        info("Workspace", workspaces.first { $0.groups.contains(where: { $0.id == g.id }) }?.name ?? "—")
        info("Panes", String(g.root?.panes.count ?? 0))
        info("Windows", String(g.memberIDs.count))
        Picker(
            d("Display"),
            selection: Binding(
                get: { g.displayID ?? "" },
                set: { value in
                    model.editGroup(g.id) { $0.displayID = value.isEmpty ? nil : value }
                })
        ) {
            Text(d("Primary display")).tag("")
            ForEach(model.displays) { display in Text(display.name).tag(display.id) }
            if let id = g.displayID, !model.displays.contains(where: { $0.id == id }) { Text(d("Disconnected display")).tag(id) }
        }
        Menu {
            Button(d("Automatic")) { model.change { $0.groupAreas.removeValue(forKey: g.id) } }
            ForEach(Array(["Left half", "Right half", "Full display", "Center"].enumerated()), id: \.offset) { i, key in
                Button(d(key)) { model.position(g.id, region: i) }
            }
        } label: {
            Label(d("Group area"), systemImage: "rectangle.dashed")
        }
        Divider()
        if editor != g.id {
            Button {
                selectGroup(g, edit: true)
            } label: {
                Label(d("Edit layout"), systemImage: "slider.horizontal.3")
            }
        }
        Button {
            model.apply(g.id)
        } label: {
            Label(d("Apply layout"), systemImage: "rectangle.on.rectangle")
        }
        .disabled(!model.trusted || g.memberIDs.isEmpty)
        if !g.memberIDs.isEmpty {
            Divider()
            Text(d("Members")).font(.headline)
            ForEach(g.memberIDs, id: \.self) { id in
                Button {
                    inspectMember(id)
                } label: {
                    HStack {
                        DeskIcon(id: id, size: 20)
                        Text(model.displayName(id)).lineLimit(1)
                        Spacer()
                        if !model.windows.contains(where: { $0.id == id }) {
                            Image(systemName: "link.badge.plus").foregroundStyle(.orange)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).onDrag { DeskPayload.window(id).provider }.contextMenu { memberMenu(id) }
            }
        }
    }
    @ViewBuilder func windowInspector(_ id: UUID) -> some View {
        HStack {
            DeskIcon(id: id, size: 38); Spacer(); iconButton("Back to group", "arrow.uturn.backward") { member = nil }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(live?.appName ?? model.state.identities[id]?.bundleID ?? d("Window")).font(.caption).foregroundStyle(.secondary)
            Text(model.displayName(id)).font(.title3.weight(.semibold)).textSelection(.enabled)
        }
        Divider()
        if let w = live {
            info("Application ID", w.bundleID)
            info("Kind", d(w.kind.rawValue))
            info("Movement", d(w.movable ? "Movable" : "Fixed position"))
            info("Resizing", d(w.resizable ? "Resizable" : "Fixed size"))
            info("Recovery", d(w.identity.permitsRecovery ? "Identity available" : "Manual reconnection"))

            info("Position", "\(Int(w.frame.minX)), \(Int(w.frame.minY))")
            info("Size", "\(Int(w.frame.width)) × \(Int(w.frame.height))")
            if let display = model.displays.max(by: { a, b in
                let ra = a.frame.intersection(w.frame), rb = b.frame.intersection(w.frame)
                return ra.width * ra.height < rb.width * rb.height
            }), display.frame.intersects(w.frame) {
                info("Display", display.name)
            }
            info("State", d(w.fullscreen ? "Full screen" : w.minimized ? "Minimized" : w.focused ? "Focused" : "Available"))
        } else {
            Label(d("Window unavailable"), systemImage: "link.badge.plus").foregroundStyle(.orange)
            if let g = group {
                Button(d("Reconnect window")) { picker = DeskPickerRequest(group: g.id, rebind: id) }
            }
        }
        if let g = group {
            Divider()
            info("Window group", g.name)
            info("Workspace", workspaces.first { $0.groups.contains(where: { $0.id == g.id }) }?.name ?? "—")
            info("Mode", d(g.floating.contains(id) ? "Floating" : "Tiled"))
            Button(d("Edit layout")) { selectGroup(g, edit: true) }
        }
        if live != nil {
            Button(d("Focus window")) { focusMember(id) }
            PreviewButton(member: id)
        }
        Menu(d("Window actions")) { memberMenu(id) }
    }
    func focusMember(_ id: UUID) {
        if let g = allGroups.first(where: { $0.root?.panes.contains(where: { $0.tabs.contains(id) }) == true }) {
            model.selectTab(id, group: g.id)
        } else {
            model.focus(id)
        }
    }
    @ViewBuilder func memberMenu(_ id: UUID) -> some View {
        let owner = allGroups.first { $0.memberIDs.contains(id) }
        let w = model.windows.first { $0.id == id }
        if w != nil { Button(d("Focus window")) { focusMember(id) } }
        if let g = owner {
            Button(d(g.floating.contains(id) ? "Tile window" : "Float window")) {
                model.editGroup(g.id) { $0.setFloating(id, !g.floating.contains(id)) }
            }
            if let p = g.root?.panes.first(where: { $0.tabs.contains(id) }), let i = p.tabs.firstIndex(of: id), p.tabs.count > 1 {
                Button(d("Move tab earlier")) { model.editGroup(g.id) { $0.reorder(id, to: i - 1) } }.disabled(i == 0)
                Button(d("Move tab later")) { model.editGroup(g.id) { $0.reorder(id, to: i + 1) } }.disabled(i == p.tabs.count - 1)
            }
            if w == nil { Button(d("Reconnect window")) { picker = DeskPickerRequest(group: g.id, rebind: id) } }
        }
        if let w, w.kind == .normal, !w.fullscreen {
            Menu(d("Position window")) {
                ForEach(Array(["Left half", "Right half", "Full display", "Center"].enumerated()), id: \.offset) { i, key in
                    Button(d(key)) { model.tile(id, region: i) }
                }
            }
            Menu(d("Move to group")) {
                ForEach(workspaces) { space in
                    Section(space.name) {
                        ForEach(space.groups.filter { $0.id != owner?.id }) { dest in
                            Button(dest.name) {
                                model.bind(id, to: dest.id); inspectMember(id)
                            }
                        }
                    }
                }
            }.disabled(!allGroups.contains(where: { $0.id != owner?.id }))
            Menu(d("Create assignment rule")) {
                ForEach(workspaces) { space in
                    Section(space.name) {
                        ForEach(space.groups) { g in
                            Button(g.name) {
                                let rule = AssignmentRule(bundleID: w.bundleID, titleContains: w.title, group: g.id)
                                model.change { $0.prefs.rules.append(rule) }
                            }
                        }
                    }
                }
            }.disabled(allGroups.isEmpty)
        }
        if owner != nil {
            Button(d("Release from group")) {
                model.release(id); member = nil; pane = nil
            }
        }
        if w != nil {
            Divider()
            Button(d("Exclude window")) {
                model.exclude(id, app: false); member = nil
            }
            Button(d("Exclude application")) {
                model.exclude(id, app: true); member = nil
            }
        }
    }
}

struct DeskIcon: View {
    @EnvironmentObject var model: Workbench
    let id: UUID
    let size: CGFloat
    var body: some View {
        Group {
            if let icon = model.icon(id) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct DeskWindowList: View {
    let windows: [LiveWindow]
    let select: (UUID) -> Void
    var selected: UUID?
    var combine: ((UUID, UUID) -> Void)? = nil
    var menu: (LiveWindow) -> AnyView = { _ in AnyView(EmptyView()) }
    @State var filter = ""
    @State var app = ""
    @State var dropTarget: UUID?
    var body: some View {
        let list = windows.filter {
            (app.isEmpty || app == $0.bundleID)
                && (filter.isEmpty || ($0.title + " " + $0.appName).localizedCaseInsensitiveContains(filter))
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(d("Filter windows"), text: $filter).textFieldStyle(.roundedBorder)
                Picker(d("Application"), selection: $app) {
                    Text(d("All applications")).tag("")
                    ForEach(
                        Dictionary(grouping: windows, by: \.bundleID).compactMap { $0.value.first }.sorted {
                            $0.appName < $1.appName
                        }
                    ) { sample in
                        Text(sample.appName).tag(sample.bundleID)
                    }
                }.labelsHidden().fixedSize()
            }
            if list.isEmpty {
                ContentUnavailableView(
                    d("No matching windows"), systemImage: "macwindow",
                    description: Text(d("Open an application window or adjust the filters.")))
            }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(list) { w in
                    Button {
                        select(w.id)
                    } label: {
                        HStack(spacing: 11) {
                            DeskIcon(id: w.id, size: 27)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.title.isEmpty ? w.appName : w.title).fontWeight(.medium).lineLimit(1)
                                Text(w.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if w.minimized || w.fullscreen {
                                Text(d(w.fullscreen ? "Full screen" : "Minimized")).font(.caption).foregroundStyle(.secondary)
                            }
                            if selected == w.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                        }.padding(8).contentShape(Rectangle())
                            .background(
                                selected == w.id ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).onDrag { DeskPayload.window(w.id).provider }.contextMenu { menu(w) }
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropTarget == w.id ? Color.accentColor : .clear))
                        .onDrop(
                            of: combine == nil ? [] : [DeskPayload.type],
                            delegate: DeskPaneDrop(
                                size: .zero,
                                update: { edge in
                                    if edge != nil { dropTarget = w.id } else if dropTarget == w.id { dropTarget = nil }
                                },
                                perform: { payload, _ in
                                    if case let .window(id) = payload, id != w.id { combine?(id, w.id) }
                                }))
                }
            }
        }
        .onChange(of: windows.map(\.bundleID)) { _, ids in if !app.isEmpty && !ids.contains(app) { app = "" } }
    }
}

struct DeskPicker: View {
    @EnvironmentObject var model: Workbench
    @Environment(\.dismiss) var dismiss
    let request: DeskPickerRequest
    @State var selection: UUID?
    var body: some View {
        let members = Set(model.state.workspaces.flatMap(\.groups).flatMap(\.memberIDs))
        let candidates = model.windows.filter { w in
            guard w.kind == .normal && !w.fullscreen else { return false }
            if let missing = request.rebind {
                return w.bundleID == model.state.identities[missing]?.bundleID && !members.contains(w.id)
            }
            return true
        }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(d(request.rebind == nil ? "Add windows" : "Reconnect window")).font(.title2.bold())
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.help(d("Refresh"))
            }
            if !model.trusted {
                Button(d("Open Accessibility settings")) { model.requestPermission() }
            }
            ScrollView {
                DeskWindowList(windows: candidates, select: { selection = $0 }, selected: selection)
            }
            HStack {
                if let selection,
                    let owner = model.state.workspaces.flatMap(\.groups).first(where: { $0.memberIDs.contains(selection) })
                {
                    Text(d("Current group") + " · " + owner.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(d("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(d(request.rebind == nil ? "Add window" : "Reconnect")) {
                    guard let selection else { return }
                    if let missing = request.rebind {
                        model.rebind(missing, to: selection)
                    } else {
                        model.bind(selection, to: request.group, pane: request.pane)
                    }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!candidates.contains(where: { $0.id == selection }) || model.busy)
            }
        }.padding(22).frame(width: 480, height: 450)
    }
}
