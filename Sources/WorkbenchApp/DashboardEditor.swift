import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

extension Dashboard {
    func editGroupView(_ g: DeskGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: small ? 12 : 17) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(g.name).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                        Text(groupDetail(g)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(LayoutPreset.allCases, id: \.self) { preset in
                            Button(d(preset.rawValue)) {
                                model.editGroup(g.id) { $0.apply(preset) }; member = nil; pane = nil
                            }
                        }
                        Divider()
                        Button(d("Reset split ratios")) { model.editGroup(g.id) { $0.resetRatios() } }
                            .disabled((g.root?.panes.count ?? 0) < 2)
                    } label: {
                        Label(d("Layout"), systemImage: "rectangle.split.2x1")
                    }.fixedSize()
                    Button(d("Apply layout")) { model.apply(g.id) }.buttonStyle(.borderedProminent)
                        .disabled(!model.trusted || model.busy || g.memberIDs.isEmpty)
                }
                if !model.trusted { permissionBanner }
                let display = model.displays.first(where: { $0.id == g.displayID }) ?? model.displays.first
                HStack {
                    Label(display?.name ?? d("Primary display"), systemImage: "display").foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    if g.zoomedPane != nil {
                        Button(d("Show all panes")) { if let id = g.zoomedPane { model.editGroup(g.id) { $0.toggleZoom(id) } } }
                    }
                }
                DeskLayoutCanvas(
                    group: g, selection: $pane, member: $member,
                    select: { p, id in
                        pane = p; member = id; selectedGroup = g.id
                    }, add: { p in picker = DeskPickerRequest(group: g.id, pane: p) }
                )
                .aspectRatio(
                    display.map { max(1.25, min(2.5, $0.frame.width / max(1, $0.frame.height))) } ?? 1.6, contentMode: .fit
                )
                .frame(maxWidth: .infinity)
                Text(d("Drop a window in the center to add a tab or on an edge to split. Drag a divider to resize."))
                    .font(.caption).foregroundStyle(.secondary)
                let missing = g.memberIDs.filter { model.bindings[$0] == nil }
                if !missing.isEmpty {
                    Text(d("Missing windows")).font(.headline)
                    ForEach(missing, id: \.self) { id in
                        HStack {
                            Image(systemName: "link.badge.plus").foregroundStyle(.orange)
                            Text(model.displayName(id)).lineLimit(1)
                            Spacer()
                            Button(d("Reconnect")) { picker = DeskPickerRequest(group: g.id, rebind: id) }
                            iconButton("Release from group", "minus.circle") { releaseMember(id) }
                        }
                    }
                }
                if !g.floating.isEmpty {
                    Text(d("Floating windows")).font(.headline)
                    ForEach(g.floating, id: \.self) { id in editorWindow(id, g: g) }
                }
                if !g.memberIDs.isEmpty { DeskReleaseTarget(group: g) }
                Divider()
                HStack {
                    Text(d("Window tray")).font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        picker = DeskPickerRequest(
                            group: g.id,
                            pane: pane.flatMap { target in g.root?.panes.contains(where: { $0.id == target }) == true ? target : nil
                            })
                    } label: {
                        Label(d("Add windows"), systemImage: "plus")
                    }
                }
                let tray = model.windows.filter { $0.kind == .normal && !$0.fullscreen && !g.memberIDs.contains($0.id) }
                if tray.isEmpty { Text(d("Available windows appear here.")).font(.callout).foregroundStyle(.secondary) }
                ForEach(tray) { w in editorWindow(w.id, g: g) }
            }.padding(small ? 16 : 22)
        }
    }
    func editorWindow(_ id: UUID, g: DeskGroup) -> some View {
        HStack(spacing: 9) {
            DeskIcon(id: id, size: 23)
            Text(model.displayName(id)).lineLimit(1).font(.callout)
            Spacer()
            if !g.memberIDs.contains(id) {
                iconButton("Add window", "plus.circle") { model.bind(id, to: g.id) }
            }
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help(d("Drag window"))
        }.padding(.vertical, 3).contentShape(Rectangle())
            .onDrag { DeskPayload.window(id).provider }
            .onTapGesture { inspectMember(id) }
            .contextMenu { memberMenu(id) }
    }
}

enum DeskPayload: Sendable {
    case window(UUID), pane(group: UUID, id: UUID)
    static let type = "app.windowworkbench.layout-item"
    var provider: NSItemProvider {
        let p = NSItemProvider()
        if case let .window(id) = self { p.registerObject(id.uuidString as NSString, visibility: .ownProcess) }
        let text: String
        switch self {
        case let .window(id): text = "window/" + id.uuidString
        case let .pane(group, id): text = "pane/" + group.uuidString + "/" + id.uuidString
        }
        let data = Data(text.utf8)
        p.registerDataRepresentation(forTypeIdentifier: Self.type, visibility: .ownProcess) { callback in
            callback(data, nil)
            return nil
        }
        return p
    }
    init?(data: Data) {
        let parts = String(decoding: data, as: UTF8.self).split(separator: "/")
        if parts.count == 2, parts[0] == "window", let id = UUID(uuidString: String(parts[1])) {
            self = .window(id)
        } else if parts.count == 3, parts[0] == "pane", let group = UUID(uuidString: String(parts[1])),
            let id = UUID(uuidString: String(parts[2]))
        {
            self = .pane(group: group, id: id)
        } else {
            return nil
        }
    }
}

@MainActor private struct DeskLayoutCanvas: View {
    @EnvironmentObject var model: Workbench
    let group: DeskGroup
    @Binding var selection: UUID?
    @Binding var member: UUID?
    let select: (UUID, UUID?) -> Void
    let add: (UUID?) -> Void
    @State private var resize: (id: UUID, ratio: Double)?
    @State private var hover: (id: UUID?, edge: LayoutEdge)?
    @State private var hoveredDivider: UUID?
    init(
        group: DeskGroup, selection: Binding<UUID?>, member: Binding<UUID?>, select: @escaping (UUID, UUID?) -> Void,
        add: @escaping (UUID?) -> Void
    ) {
        self.group = group
        self._selection = selection
        self._member = member
        self.select = select
        self.add = add
    }
    var preview: DeskGroup {
        var g = group
        if let resize { g.resize(split: resize.id, ratio: resize.ratio) }
        return g
    }
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let margin: CGFloat = 8
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
            let g = preview
            let placements = g.placements(in: bounds, gap: 9)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.24))
                if placements.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "rectangle.badge.plus").font(.largeTitle).foregroundStyle(.blue)
                        Text(d("Drop a window here")).font(.headline)
                        Button(d("Choose window")) { add(nil) }
                    }.frame(width: max(0, bounds.width), height: max(0, bounds.height))
                        .background(Color.accentColor.opacity(hover == nil ? 0.04 : 0.2), in: RoundedRectangle(cornerRadius: 7))
                        .onDrop(
                            of: [DeskPayload.type],
                            delegate: DeskPaneDrop(
                                size: bounds.size, update: { edge in hover = edge.map { (nil, $0) } },
                                perform: { item, edge in drop(item, into: nil, edge: edge) })
                        )
                        .position(x: bounds.midX, y: bounds.midY)
                }
                ForEach(placements) { p in
                    paneView(p, g: g)
                        .frame(width: p.frame.width, height: p.frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6).strokeBorder(
                                selection == p.id ? Color.accentColor : Color.secondary.opacity(0.24),
                                lineWidth: selection == p.id ? 2 : 1)
                        )
                        .overlay { if let hover, hover.id == p.id { dropPreview(hover.edge, size: p.frame.size) } }
                        .onDrop(
                            of: [DeskPayload.type],
                            delegate: DeskPaneDrop(
                                size: p.frame.size,
                                update: { edge in
                                    if let edge { hover = (p.id, edge) } else if hover?.id == p.id { hover = nil }
                                }, perform: { item, edge in drop(item, into: p.id, edge: edge) })
                        )
                        .position(x: p.frame.midX, y: p.frame.midY)
                }
                if let tree = g.root, g.zoomedPane == nil {
                    ForEach(DeskDivider.dividers(tree, placements: placements)) { divider in handle(divider) }
                }
            }
        }
    }
    func paneView(_ p: PanePlacement, g: DeskGroup) -> some View {
        ZStack {
            Color.accentColor.opacity(selection == p.id ? 0.10 : 0.045)
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.caption).foregroundStyle(.secondary).padding(3)
                        .onDrag { DeskPayload.pane(group: g.id, id: p.id).provider }.help(d("Drag to swap panes"))
                        .accessibilityLabel(d("Drag to swap panes"))
                    if p.tabs.count > 1 { Text(String(p.tabs.count)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    Spacer(minLength: 1)
                    if p.frame.width > 76 {
                        Button {
                            add(p.id)
                        } label: {
                            Image(systemName: "plus").frame(width: 17)
                        }
                        .buttonStyle(.borderless).help(d("Add window")).accessibilityLabel(d("Add window"))
                    }
                }.padding(5)
                Spacer(minLength: 0)
                if let active = p.active, !p.tabs.isEmpty {
                    if model.bindings[active] == nil {
                        Label(d("Missing"), systemImage: "link.badge.plus").font(.caption).foregroundStyle(.orange)
                    } else if p.frame.height > 82 {
                        DeskIcon(id: active, size: min(37, p.frame.width * 0.28))
                    }
                    Text(model.displayName(active)).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 5).onDrag { DeskPayload.window(active).provider }
                } else {
                    Button(d("Choose window")) { add(p.id) }.buttonStyle(.borderless).font(.callout)
                }
                Spacer(minLength: 0)
                if p.tabs.count > 1, p.frame.height > 61 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 3) {
                            ForEach(p.tabs, id: \.self) { id in
                                Button {
                                    select(p.id, id)
                                    model.editGroup(g.id) { $0.activate(id) }
                                } label: {
                                    Text(model.displayName(id)).font(.caption2).lineLimit(1).frame(maxWidth: 70)
                                        .padding(.horizontal, 4).padding(.vertical, 3)
                                        .background(
                                            id == p.active ? Color.accentColor.opacity(0.18) : .clear,
                                            in: RoundedRectangle(cornerRadius: 3))
                                }.buttonStyle(.plain).onDrag { DeskPayload.window(id).provider }
                            }
                        }
                    }.scrollIndicators(.hidden).padding(4)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(p.id, p.active) }
        .contextMenu {
            Button(d("Add window")) { add(p.id) }
            Button(d(g.zoomedPane == p.id ? "Show all panes" : "Maximize pane")) { model.editGroup(g.id) { $0.toggleZoom(p.id) } }
            if p.tabs.count > 1 {
                Button(d("Split tabs into panes")) { model.editGroup(g.id) { $0.unstack(p.id) } }
            }
            if let id = p.active {
                Button(d("Float window")) { model.editGroup(g.id) { $0.setFloating(id, true) } }
                Button(d("Release from group")) { model.release(id) }
            }
        }
    }
    func drop(_ item: DeskPayload, into pane: UUID?, edge: LayoutEdge) {
        hover = nil
        switch item {
        case let .window(id):
            model.bind(id, to: group.id, pane: pane, edge: edge)
            if let g = model.state.workspaces.flatMap(\.groups).first(where: { $0.id == group.id }),
                let p = g.root?.panes.first(where: { $0.tabs.contains(id) })
            {
                select(p.id, id)
            }
        case let .pane(source, id):
            guard source == group.id, let pane, id != pane else { return }
            model.editGroup(group.id) { $0.swapPanes(id, pane) }
        }
    }
    func dropPreview(_ edge: LayoutEdge, size: CGSize) -> some View {
        let halfWidth = edge == .left || edge == .right
        let halfHeight = edge == .top || edge == .bottom
        let align: Alignment =
            switch edge {
            case .left: .leading
            case .right: .trailing
            case .top: .top
            case .bottom: .bottom
            case .center: .center
            }
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: size.width * (halfWidth ? 0.5 : 1), height: size.height * (halfHeight ? 0.5 : 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
            .allowsHitTesting(false)
    }
    func handle(_ v: DeskDivider) -> some View {
        let horizontal = v.axis == .horizontal
        return ZStack {
            Color.clear
            Capsule().fill(hoveredDivider == v.id || resize?.id == v.id ? Color.accentColor : Color.secondary.opacity(0.36))
                .frame(width: horizontal ? 2.5 : min(24, v.frame.width), height: horizontal ? min(24, v.frame.height) : 2.5)
        }
        .frame(width: max(1, v.frame.width), height: max(1, v.frame.height))
        .contentShape(Rectangle())
        .onHover { inside in hoveredDivider = inside ? v.id : nil }
        .overlay {
            DeskDividerControl(
                horizontal: horizontal, ratio: v.ratio,
                length: horizontal ? v.bounds.width - v.frame.width : v.bounds.height - v.frame.height,
                update: { value, finished in
                    var ratio = max(0.04, min(0.96, value))
                    if model.state.prefs.snapRatios,
                        let snap = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75].first(where: { abs($0 - ratio) < 0.023 })
                    {
                        ratio = snap
                    }
                    if finished {
                        if abs(v.ratio - ratio) > 0.0001 || resize != nil {
                            model.editGroup(group.id) { $0.resize(split: v.id, ratio: ratio) }
                        }
                        resize = nil
                    } else {
                        resize = (v.id, ratio)
                    }
                })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(d("Split ratio"))
        .accessibilityValue("\(Int(v.ratio * 100))%")
        .accessibilityAdjustableAction { direction in
            let change = direction == .increment ? 0.05 : -0.05
            model.editGroup(group.id) { $0.resize(split: v.id, ratio: v.ratio + change) }
        }
        .position(x: v.frame.midX, y: v.frame.midY)
    }
}

private struct DeskDividerControl: NSViewRepresentable {
    let horizontal: Bool
    let ratio: Double
    let length: CGFloat
    let update: (Double, Bool) -> Void

    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ view: Grip, context: Context) {
        view.horizontal = horizontal
        view.ratio = ratio
        view.length = max(length, 1)
        view.update = update
    }

    final class Grip: NSView {
        var horizontal = true
        var ratio = 0.5
        var length: CGFloat = 1
        var update: ((Double, Bool) -> Void)?
        private var start: (point: CGPoint, ratio: Double)?

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: horizontal ? .resizeLeftRight : .resizeUpDown)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { start = (event.locationInWindow, ratio) }
        override func mouseDragged(with event: NSEvent) { adjust(event, finished: false) }
        override func mouseUp(with event: NSEvent) {
            adjust(event, finished: true)
            start = nil
        }
        private func adjust(_ event: NSEvent, finished: Bool) {
            guard let start else { return }
            let point = event.locationInWindow
            let delta = horizontal ? point.x - start.point.x : start.point.y - point.y
            update?(start.ratio + Double(delta / length), finished)
        }
    }
}

private struct DeskDivider: Identifiable {
    let id: UUID
    let axis: SplitAxis
    let ratio: Double
    let bounds: CGRect
    let frame: CGRect
    static func dividers(_ node: LayoutNode, placements: [PanePlacement]) -> [Self] {
        let frames = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0.frame) })
        var values: [Self] = []
        func visit(_ node: LayoutNode) -> CGRect {
            switch node {
            case let .pane(id, _, _): return frames[id] ?? .null
            case let .split(id, axis, ratio, first, second):
                let a = visit(first), b = visit(second), rect = a.union(b)
                guard !a.isNull, !b.isNull else { return rect }
                let gutter =
                    axis == .horizontal
                    ? CGRect(x: a.maxX, y: rect.minY, width: max(0, b.minX - a.maxX), height: rect.height)
                    : CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: max(0, b.minY - a.maxY))
                values.append(Self(id: id, axis: axis, ratio: ratio, bounds: rect, frame: gutter))
                return rect
            }
        }
        _ = visit(node)
        return values
    }
}

private struct DeskReleaseTarget: View {
    @EnvironmentObject var model: Workbench
    let group: DeskGroup
    @State var targeted = false
    var body: some View {
        Label(d("Drop here to release from group"), systemImage: "rectangle.portrait.and.arrow.right")
            .font(.callout).foregroundStyle(targeted ? Color.accentColor : .secondary)
            .padding(8).frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(targeted ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(
                    Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            )
            .onDrop(
                of: [DeskPayload.type],
                delegate: DeskPaneDrop(
                    size: .zero, update: { targeted = $0 != nil },
                    perform: { payload, _ in
                        if case let .window(id) = payload, group.memberIDs.contains(id) { model.release(id) }
                    }))
    }
}

struct DeskPaneDrop: DropDelegate {
    let size: CGSize
    let update: (LayoutEdge?) -> Void
    let perform: @MainActor (DeskPayload, LayoutEdge) -> Void
    func edge(_ point: CGPoint) -> LayoutEdge {
        let x = point.x / max(1, size.width), y = point.y / max(1, size.height)
        let options: [(CGFloat, LayoutEdge)] = [(x, .left), (1 - x, .right), (y, .top), (1 - y, .bottom)]
        guard let best = options.min(by: { $0.0 < $1.0 }), best.0 < 0.24 else { return .center }
        return best.1
    }
    func dropEntered(info: DropInfo) { update(edge(info.location)) }
    func dropExited(info: DropInfo) { update(nil) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(edge(info.location))
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [DeskPayload.type]).first else { return false }
        let target = edge(info.location)
        update(nil)
        provider.loadDataRepresentation(forTypeIdentifier: DeskPayload.type) { data, _ in
            guard let data, let payload = DeskPayload(data: data) else { return }
            Task { @MainActor in perform(payload, target) }
        }
        return true
    }
}
