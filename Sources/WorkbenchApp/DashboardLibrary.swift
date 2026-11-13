import SwiftUI
import WorkbenchCore

extension Dashboard {
    var spacesOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                HStack {
                    Text(d("All workspaces")).font(.largeTitle.weight(.semibold))
                    Spacer()
                    viewPicker
                    Button(action: addWorkspace) { Label(d("New workspace"), systemImage: "plus") }
                }
                if grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 182, maximum: 340), spacing: 14)], spacing: 14) {
                        ForEach(workspaces) { w in workspaceCard(w) }
                    }
                } else {
                    ForEach(workspaces) { w in
                        workspaceCard(w); Divider()
                    }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    func workspaceCard(_ w: Workspace) -> some View {
        let active = model.state.activeID == w.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                activateWorkspace(w.id)
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    if grid {
                        if w.groups.isEmpty {
                            Image(systemName: "rectangle.stack").font(.title).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).frame(height: small ? 60 : 85)
                        } else {
                            HStack(spacing: 2) { ForEach(Array(w.groups.prefix(3))) { g in DeskPreview(group: g) } }
                                .frame(height: small ? 60 : 85)
                        }
                    }
                    HStack {
                        Text(w.name).font(.headline).lineLimit(1)
                        Spacer()
                        if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue).help(d("Active workspace")) }
                    }
                    Text(workspaceDetail(w)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy)
                .accessibilityHint(d("Activate workspace"))
                .accessibilityValue(active ? d("Active workspace") : "")
            HStack {
                Button(d("Edit layout")) { openSpaceEditor(w) }.controlSize(.small)
                Spacer()
                Menu {
                    workspaceMenu(w)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(d("Workspace actions"))
            }.padding(.top, 8)
        }.padding(small ? 8 : 11)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active ? Color.accentColor : Color.secondary.opacity(0.2)))
            .contextMenu { workspaceMenu(w) }
    }
    func workspaceDetail(_ w: Workspace) -> String {
        var parts = [
            deskCount(w.groups.count, "group", "groups"), deskCount(w.groups.flatMap(\.memberIDs).count, "window", "windows"),
        ]
        let missing = model.missingCount(in: w)
        if missing > 0 { parts.append(deskCount(missing, "missing", "missing")) }
        return parts.joined(separator: "  ·  ")
    }
    var viewPicker: some View {
        Picker(d("View"), selection: $grid) {
            Image(systemName: "square.grid.2x2").tag(true).help(d("Grid view"))
            Image(systemName: "list.bullet").tag(false).help(d("List view"))
        }.labelsHidden().pickerStyle(.segmented).frame(width: 68)
    }
    func openSpaceEditor(_ w: Workspace) {
        navigate(.workspace(w.id))
        if let g = w.groups.first { selectGroup(g, edit: true) } else { addGroup(w.id) }
    }
    var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: small ? 16 : 23) {
                if let w = workspace {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(w.name).font(.system(size: 28, weight: .semibold)).lineLimit(2)
                            Text(workspaceDetail(w)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.state.activeID == w.id {
                            Label(d("Active workspace"), systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.blue)
                        } else {
                            Button(d("Activate workspace")) { activateWorkspace(w.id) }.disabled(model.busy)
                        }
                        Menu {
                            workspaceMenu(w)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(d("Workspace actions"))
                    }
                    if !model.trusted { permissionBanner }
                    HStack {
                        Text(d("Window groups")).font(.title3.weight(.semibold))
                        Spacer()
                        viewPicker
                        Button {
                            addGroup(w.id)
                        } label: {
                            Label(d("New group"), systemImage: "plus")
                        }
                    }
                    if w.groups.isEmpty {
                        emptyWorkspace(w)
                    } else if grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 177, maximum: 340), spacing: 14)], spacing: 14) {
                            ForEach(w.groups) { g in groupCard(g) }
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(w.groups) { g in
                                groupCard(g)
                                Divider()
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(d("Create your first workspace"), systemImage: "rectangle.stack.badge.plus")
                    } actions: {
                        Button(d("New workspace"), action: addWorkspace)
                    }
                }
            }.padding(small ? 17 : 23).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var permissionBanner: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "accessibility").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 5) {
                Text(d("Connect your Mac windows")).fontWeight(.semibold)
                Text(d("Allow Accessibility access to find, move and switch windows.")).font(.callout).foregroundStyle(.secondary)
                Button(d("Open Accessibility settings")) { model.requestPermission() }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
    }
    func emptyWorkspace(_ w: Workspace) -> some View {
        VStack(alignment: .center, spacing: 15) {
            Canvas { ctx, size in
                let ink = Color.accentColor
                let x = size.width / 2 - 82, y = size.height / 2 - 40
                let outer = CGRect(x: x, y: y, width: 164, height: 85)
                let shell = Path(roundedRect: outer, cornerRadius: 7)
                ctx.fill(shell, with: .color(Color(nsColor: .windowBackgroundColor)))
                ctx.stroke(shell, with: .color(ink.opacity(0.38)), lineWidth: 1.3)
                let panes = [
                    CGRect(x: x + 6, y: y + 7, width: 92, height: 71),
                    CGRect(x: x + 103, y: y + 7, width: 55, height: 33),
                    CGRect(x: x + 103, y: y + 45, width: 55, height: 33),
                ]
                for (i, r) in panes.enumerated() {
                    let p = Path(roundedRect: r, cornerRadius: 3)
                    ctx.fill(p, with: .color(ink.opacity(i == 0 ? 0.17 : 0.07)))
                    ctx.stroke(p, with: .color(ink.opacity(0.25)), lineWidth: 1)
                    ctx.fill(
                        Path(
                            roundedRect: CGRect(x: r.minX + 5, y: r.minY + 5, width: r.width * 0.38, height: 3), cornerRadius: 1.5),
                        with: .color(ink.opacity(0.45)))
                }
            }.frame(height: 93).accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(d("Build your first window group")).font(.title3.weight(.semibold))
                Text(d("Keep related windows together in tabs or split them across your display."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 325)
            }
            Button {
                addGroup(w.id)
            } label: {
                Label(d("Create window group"), systemImage: "plus")
            }.buttonStyle(.borderedProminent)
        }.padding(25).frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13).strokeBorder(
                    Color.secondary.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
    func groupDetail(_ g: DeskGroup) -> String {
        deskCount(g.root?.panes.count ?? 0, "pane", "panes") + "  ·  " + deskCount(g.memberIDs.count, "window", "windows")
    }
    func groupCard(_ g: DeskGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                focusGroup(g)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    if grid { DeskPreview(group: g).frame(height: small ? 70 : 95) }
                    Text(g.name).font(.headline).lineLimit(1)
                    Text(groupDetail(g)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy || g.memberIDs.isEmpty).accessibilityHint(d("Focus group"))
            HStack {
                Button(d("Edit layout")) { selectGroup(g, edit: true) }
                Button(d("Apply layout")) { model.apply(g.id) }.disabled(model.busy || g.memberIDs.isEmpty)
                Spacer(minLength: 1)
                Menu {
                    groupMenu(g)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(d("Group actions"))
            }.controlSize(.small).padding(.top, 8)
        }.padding(small ? 8 : 11)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9).strokeBorder(
                    selectedGroup == g.id ? Color.accentColor : Color.secondary.opacity(0.2))
            )
            .contextMenu { groupMenu(g) }
    }
    var windowsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text(d("All windows")).font(.largeTitle.weight(.semibold))
                    Spacer()
                    iconButton("Refresh", "arrow.clockwise") { model.refresh() }
                }
                if !model.trusted { permissionBanner }
                if workspace != nil && model.windows.count > 1 {
                    Text(d("Drop one window onto another to create a tab group.")).font(.caption).foregroundStyle(.secondary)
                }
                DeskWindowList(
                    windows: model.windows, select: { inspectMember($0) }, selected: member,
                    combine: { first, second in
                        if let w = workspace { model.combine(first, second, in: w.id) }
                    }
                ) { live in
                    AnyView(memberMenu(live.id))
                }
            }.padding(22)
        }
    }
    var templatesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(d("Templates")).font(.largeTitle.weight(.semibold))
                if model.state.templates.isEmpty {
                    ContentUnavailableView(
                        d("No saved templates"), systemImage: "square.grid.2x2",
                        description: Text(d("Use Save as template in a group’s menu to reuse its layout.")))
                } else {
                    ForEach(model.state.templates) { t in
                        HStack(spacing: 13) {
                            DeskPreview(group: t).frame(width: 73, height: 46).clipShape(RoundedRectangle(cornerRadius: 5))
                            Text(t.name).fontWeight(.medium)
                            Spacer()
                            Menu(d("Use template")) {
                                ForEach(workspaces) { w in
                                    Button(w.name) {
                                        model.useTemplate(t.id, workspace: w.id); navigate(.workspace(w.id))
                                    }
                                }
                            }.fixedSize().disabled(workspaces.isEmpty)
                            iconButton("Delete template", "trash") {
                                deleting = DeskNameRequest(title: d("Delete template") + "?", value: t.name) { _ in
                                    model.change { $0.templates.removeAll { $0.id == t.id } }
                                }
                            }
                        }
                        Divider()
                    }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var recentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text(d("Recent workspaces")).font(.largeTitle.weight(.semibold))
                let recent = model.state.recent.compactMap { id in workspaces.first { $0.id == id } }
                if recent.isEmpty {
                    ContentUnavailableView(
                        d("No recent workspaces"), systemImage: "clock",
                        description: Text(d("Workspaces appear here when you activate them.")))
                }
                ForEach(recent) { w in
                    resultRow(w.name, symbol: "rectangle.stack", detail: deskCount(w.groups.count, "group", "groups")) {
                        activateWorkspace(w.id)
                    }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var searchResults: some View {
        let ws = workspaces.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let gs = allGroups.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let wins = model.windows.filter { ($0.appName + " " + $0.title).localizedCaseInsensitiveContains(search) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                Text(d("Search results")).font(.title.bold()).padding(.bottom, 7)
                if !ws.isEmpty { Text(d("Workspaces")).font(.headline).foregroundStyle(.secondary) }
                ForEach(ws) { w in
                    resultRow(w.name, symbol: "rectangle.stack", detail: workspaceDetail(w)) { activateWorkspace(w.id) }
                }
                if !gs.isEmpty { Text(d("Window groups")).font(.headline).foregroundStyle(.secondary) }
                ForEach(gs) { g in
                    resultRow(g.name, symbol: "rectangle.3.group", detail: groupDetail(g)) { focusGroup(g) }
                }
                if !wins.isEmpty { Text(d("Windows")).font(.headline).foregroundStyle(.secondary) }
                ForEach(wins) { w in
                    resultRow(w.title.isEmpty ? w.appName : w.title, symbol: "macwindow", detail: w.appName) {
                        navigate(.windows); inspectMember(w.id)
                    }
                }
                if ws.isEmpty && gs.isEmpty && wins.isEmpty { ContentUnavailableView.search(text: search) }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    func resultRow(_ title: String, symbol: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.blue).frame(width: 25)
                Text(title).lineLimit(1)
                Spacer()
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.contentShape(Rectangle()).padding(.vertical, 7)
        }.buttonStyle(.plain)
    }
}

struct DeskPreview: View {
    @EnvironmentObject var model: Workbench
    let group: DeskGroup
    var body: some View {
        Canvas { ctx, size in
            let margin = min(size.width, size.height) * 0.115
            let canvas = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
            var dot = Path()
            for x in stride(from: 4, through: size.width, by: 8) {
                for y in stride(from: 4, through: size.height, by: 8) {
                    dot.addEllipse(in: CGRect(x: x, y: y, width: 1.1, height: 1.1))
                }
            }
            ctx.fill(dot, with: .color(Color.secondary.opacity(0.22)))
            let frames = group.placements(in: canvas, gap: max(2, margin * 0.36))
            if frames.isEmpty {
                ctx.stroke(
                    Path(roundedRect: canvas, cornerRadius: 4), with: .color(.secondary.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            for (index, p) in frames.enumerated() {
                let tile = Path(roundedRect: p.frame, cornerRadius: 3)
                let hue = Color.accentColor
                ctx.fill(tile, with: .color(Color(nsColor: .windowBackgroundColor)))
                ctx.fill(tile, with: .color(hue.opacity(index == 0 ? 0.17 : 0.08)))
                ctx.stroke(tile, with: .color(hue.opacity(0.47)), lineWidth: 1)
                if let active = p.active, size.height >= 64, p.frame.width > 28, p.frame.height > 26 {
                    let title = model.displayName(active)
                    let font: Font = .system(size: 9, weight: .medium)
                    let label = Text(verbatim: String(title.prefix(max(1, Int(p.frame.width / 6) - 2)))).font(font).foregroundStyle(
                        .secondary)
                    ctx.draw(label, at: CGPoint(x: p.frame.midX, y: p.frame.midY + 4))
                }
                if p.frame.width > 16 && p.frame.height > 12 {
                    let bar = CGRect(x: p.frame.minX + 4, y: p.frame.minY + 4, width: min(32, p.frame.width * 0.33), height: 2.5)
                    ctx.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(hue.opacity(0.55)))
                }
            }
        }.background(Color(nsColor: .windowBackgroundColor)).accessibilityHidden(true)
    }
}
