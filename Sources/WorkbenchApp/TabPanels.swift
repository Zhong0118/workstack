import AppKit
import SwiftUI
import WorkbenchCore

private final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TabPanels {
    static func height(_ prefs: Preferences) -> CGFloat { prefs.tabStyle == "compact" ? 23 : 29 }
    private unowned let model: Workbench
    private var panels: [UUID: StripPanel] = [:]
    private var contents: [UUID: String] = [:]
    private var expanded: Set<UUID> = []
    init(model: Workbench) { self.model = model }

    func close() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        contents.removeAll()
        expanded.removeAll()
    }
    func sync() {
        guard !model.terminating else { close(); return }
        var kept = Set<UUID>()
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for g in model.activeWorkspace?.groups ?? [] where model.engagedGroups.contains(g.id) {
            for p in g.root?.panes ?? [] where p.tabs.count > 1 {
                kept.insert(p.id)
                guard model.trusted, !NSApp.isActive,
                    g.zoomedPane == nil || g.zoomedPane == p.id,
                    let w = model.windows.first(where: { $0.id == p.active && $0.focused && !$0.minimized && !$0.fullscreen })
                else {
                    panels[p.id]?.orderOut(nil)
                    continue
                }
                let bar = panels[p.id] ?? makePanel()
                panels[p.id] = bar
                let compact = model.state.prefs.tabAutoHide && !expanded.contains(p.id)
                let height = compact ? 5 : Self.height(model.state.prefs)
                let area =
                    model.displays.max { a, b in
                        let x = a.frame.intersection(w.frame), y = b.frame.intersection(w.frame)
                        return x.width * x.height < y.width * y.height
                    }?.frame ?? w.frame
                let top = model.state.prefs.tabPosition == "top"
                let y = max(area.minY, min(area.maxY - height, top ? w.frame.minY - height : w.frame.maxY))
                let rect = CGRect(
                    x: w.frame.minX, y: primaryTop - y - height, width: min(w.frame.width, area.width), height: height)
                if bar.frame != rect { bar.setFrame(rect, display: false) }
                let signature =
                    p.tabs.map { $0.uuidString + model.displayName($0) }.joined() + w.id.uuidString + String(compact)
                    + model.state.prefs.theme + (model.state.prefs.tabStyle ?? "")
                if contents[p.id] != signature {
                    contents[p.id] = signature
                    let strip = TabStrip(model: model, group: g.id, pane: p, compact: compact) { [weak self] hovering in
                        guard let self, model.state.prefs.tabAutoHide else { return }
                        if hovering { expanded.insert(p.id) } else { expanded.remove(p.id) }
                        sync()
                    }
                    bar.contentView = NSHostingView(rootView: strip)
                }
                if !bar.isVisible { bar.orderFrontRegardless() }
            }
        }
        for id in Set(panels.keys).subtracting(kept) {
            panels.removeValue(forKey: id)?.orderOut(nil)
            contents.removeValue(forKey: id)
            expanded.remove(id)
        }
    }
    private func makePanel() -> StripPanel {
        let panel = StripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        return panel
    }
}

private struct TabStrip: View {
    @ObservedObject var model: Workbench
    let group: UUID
    let pane: LayoutPane
    let compact: Bool
    let hovered: (Bool) -> Void
    var body: some View {
        Group {
            if compact {
                Capsule().fill(Color.accentColor.opacity(0.65)).padding(.horizontal, 6)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(Array(pane.tabs.enumerated()), id: \.element) { index, id in
                            Button {
                                model.selectTab(id, group: group)
                            } label: {
                                HStack(spacing: 4) {
                                    if let img = model.icon(id) { Image(nsImage: img).resizable().frame(width: 15, height: 15) }
                                    Text(verbatim: model.displayName(id)).lineLimit(1)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5).fill(
                                        id == pane.active ? Color.accentColor.opacity(0.21) : .clear))
                            }.buttonStyle(.plain).disabled(model.busy || model.bindings[id] == nil)
                                .accessibilityIdentifier("workstack.tab.\(id.uuidString)")
                                .accessibilityAddTraits(id == pane.active ? .isSelected : [])
                                .onDrag { DeskPayload.window(id).provider }
                                .dropDestination(for: String.self) { values, _ in
                                    guard let first = values.first, let member = UUID(uuidString: first) else { return false }
                                    if pane.tabs.contains(member) {
                                        model.editGroup(group) { $0.reorder(member, to: index) }
                                    } else {
                                        model.bind(member, to: group, pane: pane.id)
                                    }
                                    return true
                                }
                                .contextMenu { Button(tr("Release window")) { model.release(id) } }
                        }
                    }.padding(.horizontal, 3)
                }.scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 5))
        .onHover(perform: hovered)
    }
}
