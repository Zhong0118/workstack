import AppKit
import SwiftUI
import WorkbenchCore

private final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Tells whether a pane's active window is at rest. A strip only sits on a window that stopped moving.
struct StripMotion {
    /// How long a window stays still before its strip returns.
    static let settle = Duration.milliseconds(200)
    private var reference: CGRect?
    private var moved: ContinuousClock.Instant?
    private var announced: ContinuousClock.Instant?

    /// Stacked tabs can differ by a few points when an application rounds its size, so
    /// only a change beyond the tolerance stacking accepts counts as a move.
    mutating func observe(_ frame: CGRect, at now: ContinuousClock.Instant) {
        guard let known = reference else { reference = frame; return }
        guard !known.roughlyEquals(frame, tolerance: 3) else { return }
        reference = frame
        // A move event already timed this change. Its frame only arrives a scan later and
        // must not make the strip wait a second time.
        if let announced, now < announced.advanced(by: Self.settle) { return }
        moved = now
    }

    /// A move was reported before its new frame is known.
    mutating func nudge(at now: ContinuousClock.Instant) {
        moved = now
        announced = now
    }

    /// When the window counts as settled, or nil when it already does.
    func unsettled(at now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let rest = moved?.advanced(by: Self.settle), now < rest else { return nil }
        return rest
    }
}

@MainActor
final class TabPanels {
    static func height(_ prefs: Preferences) -> CGFloat { prefs.tabStyle == "compact" ? 23 : 29 }
    /// A tab switch moves focus between two windows. The strip keeps its place across that gap.
    static let hold = Duration.milliseconds(300)
    private static let fadeIn = 0.16, fadeOut = 0.12, detach = 0.08

    private unowned let model: Workbench
    private var panels: [UUID: StripPanel] = [:]
    private var contents: [UUID: String] = [:]
    private var expanded: Set<UUID> = []
    private var motion: [UUID: StripMotion] = [:]
    private var owners: [UUID: pid_t] = [:]
    private var shown: Set<UUID> = []
    private var holdUntil: ContinuousClock.Instant?
    private var wake: (at: ContinuousClock.Instant, task: Task<Void, Never>)?
    /// Counts strips going from hidden to shown. A switch that keeps its strip leaves it unchanged.
    private(set) var presentations = 0
    init(model: Workbench) { self.model = model }

    private var animated: Bool {
        model.state.prefs.enableAnimations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func close() {
        wake?.task.cancel()
        wake = nil
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        contents.removeAll()
        expanded.removeAll()
        motion.removeAll()
        owners.removeAll()
        shown.removeAll()
    }

    /// A move or resize event precedes the snapshot carrying the new frame. Detaching on the
    /// event keeps the strip from hanging behind a window that already left.
    func windowMoved(pid: pid_t) {
        let now = ContinuousClock.now
        // Our own layout commands, and the focus changes around them, are judged from snapshots.
        guard !model.busy, holdUntil.map({ now >= $0 }) ?? true else { return }
        var attached = false
        for (id, owner) in owners where owner == pid {
            motion[id, default: StripMotion()].nudge(at: now)
            attached = attached || shown.contains(id)
        }
        // A detached strip already has a wake-up pending, which re-reads the later deadline.
        if attached { sync() }
    }

    func sync(afterOperation: Bool = false) {
        guard !model.terminating else { close(); return }
        let now = ContinuousClock.now
        if model.busy || afterOperation { holdUntil = now.advanced(by: Self.hold) }
        let holding = holdUntil.map { now < $0 } ?? false
        let focused = model.windows.first { $0.focused && !$0.minimized }
        var next: ContinuousClock.Instant?
        var kept = Set<UUID>()
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for g in model.activeWorkspace?.groups ?? [] where model.engagedGroups.contains(g.id) {
            for p in g.root?.panes ?? [] where p.tabs.count > 1 {
                kept.insert(p.id)
                let active = model.windows.first { $0.id == p.active && !$0.minimized && !$0.fullscreen }
                owners[p.id] = active?.identity.pid
                if let active { motion[p.id, default: StripMotion()].observe(active.frame, at: now) }
                guard model.trusted, !NSApp.isActive, g.zoomedPane == nil || g.zoomedPane == p.id, let w = active else {
                    hide(p.id, over: Self.fadeOut)
                    continue
                }
                guard w.focused else {
                    // Between the old tab losing focus and the new one reporting it, nothing or a
                    // sibling tab is focused. Hiding here would blink the strip on every switch.
                    if holding, shown.contains(p.id), focused.map({ p.tabs.contains($0.id) }) ?? true {
                        next = [next, holdUntil].compactMap { $0 }.min()
                    } else {
                        hide(p.id, over: Self.fadeOut)
                    }
                    continue
                }
                if let rest = motion[p.id]?.unsettled(at: now) {
                    hide(p.id, over: Self.detach)
                    next = [next, rest].compactMap { $0 }.min()
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
                    // Window titles change often. Updating the root keeps one view tree per panel.
                    if let host = bar.contentView as? NSHostingView<TabStrip> {
                        host.rootView = strip
                    } else {
                        bar.contentView = NSHostingView(rootView: strip)
                    }
                }
                show(p.id, bar)
            }
        }
        for id in Set(panels.keys).union(motion.keys).subtracting(kept) {
            panels.removeValue(forKey: id)?.orderOut(nil)
            contents.removeValue(forKey: id)
            expanded.remove(id)
            motion.removeValue(forKey: id)
            owners.removeValue(forKey: id)
            shown.remove(id)
        }
        if let next { wakeUp(at: next) }
    }

    /// Settling and the end of a hold arrive without a new snapshot, so they need their own wake-up.
    private func wakeUp(at deadline: ContinuousClock.Instant) {
        if let wake, wake.at <= deadline { return }
        wake?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.wake = nil
            self.sync()
        }
        wake = (deadline, task)
    }

    private func show(_ id: UUID, _ bar: StripPanel) {
        guard shown.insert(id).inserted else { return }
        presentations += 1
        bar.ignoresMouseEvents = false
        if !bar.isVisible {
            bar.alphaValue = animated ? 0 : 1
            bar.orderFrontRegardless()
        }
        fade(id, to: 1, over: Self.fadeIn)
    }

    private func hide(_ id: UUID, over seconds: TimeInterval) {
        guard shown.remove(id) != nil, let bar = panels[id] else { return }
        // A fading strip must not swallow a click meant for the window underneath.
        bar.ignoresMouseEvents = true
        if animated { fade(id, to: 0, over: seconds) } else { bar.orderOut(nil) }
    }

    private func fade(_ id: UUID, to alpha: CGFloat, over seconds: TimeInterval) {
        guard let bar = panels[id] else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? seconds : 0
            bar.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // The strip may have been shown again while it was fading out.
                guard let self, alpha == 0, !self.shown.contains(id) else { return }
                self.panels[id]?.orderOut(nil)
            }
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
    let model: Workbench
    let group: UUID
    let pane: LayoutPane
    let compact: Bool
    let hovered: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    /// The tab the user just pressed, highlighted before the switch is confirmed.
    @State private var pressed: UUID?

    /// The panel refreshes its root only while attached. Reading the pane from the model
    /// keeps the selection current across a switch.
    private var live: LayoutPane {
        model.groupList.first { $0.id == group }?.root?.panes.first { $0.id == pane.id } ?? pane
    }
    var body: some View {
        let pane = live
        let highlighted = pressed.flatMap { pane.tabs.contains($0) ? $0 : nil } ?? pane.active
        Group {
            if compact {
                Capsule().fill(Color.accentColor.opacity(0.65)).padding(.horizontal, 6)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(Array(pane.tabs.enumerated()), id: \.element) { index, id in
                            Button {
                                model.selectTab(id, group: group)
                                // Answer the press at once. A failed switch slides the highlight back.
                                if model.busy { pressed = id }
                            } label: {
                                HStack(spacing: 4) {
                                    if let img = model.icon(id) { Image(nsImage: img).resizable().frame(width: 15, height: 15) }
                                    Text(verbatim: model.displayName(id)).lineLimit(1)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background {
                                    if id == highlighted {
                                        RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.21))
                                            .matchedGeometryEffect(id: "selection", in: selection)
                                    }
                                }
                                .contentShape(Rectangle())
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
                        .animation(
                            reduceMotion || !model.state.prefs.enableAnimations ? nil : .snappy(duration: 0.22), value: highlighted)
                }.scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 5))
        .onHover(perform: hovered)
        .onChange(of: pane.active) { pressed = nil }
        .onChange(of: model.busy) { _, busy in if !busy { pressed = nil } }
    }
}
