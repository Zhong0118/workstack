import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import WorkbenchCore
import ScreenCaptureKit

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", workspace = "Workspaces", groups = "Window Groups", layouts = "Layouts", shortcuts = "Shortcuts",
        rules = "Rules", appearance = "Appearance", privacy = "Privacy & Permissions", about = "About"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .workspace: "square.grid.2x2"
        case .groups: "rectangle.stack"
        case .layouts: "rectangle.split.2x1"
        case .shortcuts: "keyboard"
        case .rules: "line.3.horizontal.decrease.circle"
        case .appearance: "circle.lefthalf.filled"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }
}

struct WorkbenchSettings: View {
    @EnvironmentObject var model: Workbench
    @State private var page = SettingsPage.general
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var captureGranted = CGPreflightScreenCaptureAccess()
    @State private var appID = ""
    @State private var titleMatch = ""
    @State private var target: UUID?
    @State private var status = ""
    @State private var reset = false

    func pref<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { model.state.prefs[keyPath: key] }, set: { value in model.change { $0.prefs[keyPath: key] = value } })
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.allCases) { item in
                    Button {
                        page = item
                    } label: {
                        Label(tr(item.rawValue), systemImage: item.symbol).frame(maxWidth: .infinity, alignment: .leading).padding(
                            8
                        )
                        .background(page == item ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(12).frame(width: 189).background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(tr(page.rawValue)).font(.title2.bold()).padding(20)
                Form { sections }.formStyle(.grouped)
                if !status.isEmpty || model.notice != nil {
                    Text(status.isEmpty ? model.notice ?? "" : status).font(.caption).padding(12)
                }
            }
        }.frame(width: 690, height: 490)
            .confirmationDialog(tr("Reset preferences?"), isPresented: $reset) {
                Button(tr("Restore defaults"), role: .destructive) { model.change { $0.prefs = Preferences() } }
            }
    }
    @ViewBuilder private var sections: some View {
        switch page {
        case .general:
            Toggle(
                tr("Open at login"),
                isOn: Binding(
                    get: { login },
                    set: { value in
                        do {
                            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            login = SMAppService.mainApp.status == .enabled
                            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                        } catch { status = tr("Check Login Items in System Settings.") }
                    }))
            Toggle(tr("Show menu bar item"), isOn: pref(\.menuBar))
            HStack {
                Button(tr("Export configuration")) { transfer(export: true) }
                Button(tr("Import configuration")) { transfer(export: false) }
            }
            Button(tr("Restore defaults")) { reset = true }
        case .workspace:
            Toggle(tr("Restore layouts on switch"), isOn: pref(\.switchLayouts))
            Toggle(tr("Minimize previous workspace when recoverable"), isOn: pref(\.hidePrevious))
        case .groups:
            Picker(tr("Tab bar position"), selection: pref(\.tabPosition)) {
                Text(tr("Top")).tag("top"); Text(tr("Bottom")).tag("bottom")
            }
            Picker(
                tr("Tab bar style"),
                selection: Binding(
                    get: { model.state.prefs.tabStyle ?? "standard" }, set: { val in model.change { $0.prefs.tabStyle = val } })
            ) {
                Text(tr("Standard")).tag("standard"); Text(tr("Compact")).tag("compact")
            }
            Toggle(tr("Collapse tab bar until hover"), isOn: pref(\.tabAutoHide))
            Toggle(tr("Minimize recoverable inactive tabs"), isOn: pref(\.minimizeTabs))
        case .layouts:
            Slider(value: pref(\.gap), in: 0...32, step: 1) {
                Text(tr("Gap"))
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text("\(Int(model.state.prefs.gap)) 点")
            }
            Toggle(tr("Snap dividers to common ratios"), isOn: pref(\.snapRatios))
            LabeledContent(tr("Saved layouts"), value: "\(model.state.templates.count)")
        case .shortcuts:
            Toggle(tr("Enable global shortcut"), isOn: pref(\.shortcutsEnabled))
            ForEach(ShortcutAction.allCases) { action in
                HStack {
                    Text(tr(action.name))
                    Spacer()
                    ShortcutRecorder(chord: action.binding(model.state.prefs)) { chord in
                        guard chord.isValid,
                            !ShortcutAction.allCases.contains(where: { $0 != action && $0.binding(model.state.prefs) == chord })
                        else {
                            status = tr("Choose a different shortcut with a modifier key.")
                            return
                        }
                        status = ""
                        model.change {
                            if action == .switcher {
                                $0.prefs.shortcutKey = chord.key; $0.prefs.shortcutModifiers = chord.modifiers
                            } else {
                                var chords = $0.prefs.additionalShortcuts ?? [:]
                                chords[String(action.rawValue)] = chord
                                $0.prefs.additionalShortcuts = chords
                            }
                        }
                    }
                }
            }
            Button(tr("Restore default shortcut")) {
                model.change {
                    $0.prefs.shortcutKey = 49; $0.prefs.shortcutModifiers = 6144; $0.prefs.shortcutsEnabled = true;
                    $0.prefs.additionalShortcuts = nil
                }
            }
        case .appearance:
            Picker(tr("Theme"), selection: pref(\.theme)) {
                ForEach(["system", "light", "dark"], id: \.self) { Text(tr($0.capitalized)).tag($0) }
            }
            Toggle(tr("Compact rows"), isOn: pref(\.compact))
            Toggle(tr("Interface animations"), isOn: pref(\.enableAnimations))
        case .rules: rules
        case .privacy:
            LabeledContent(tr("Accessibility"), value: tr(model.trusted ? "Granted" : "Permission required"))
            Button(tr("Review Accessibility permission")) { model.requestPermission() }
            Toggle(
                tr("Enable on-demand window previews"),
                isOn: Binding(
                    get: { model.state.prefs.previews },
                    set: { value in
                        if value { captureGranted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }
                        model.change { $0.prefs.previews = value && captureGranted }
                        if value && !captureGranted { status = tr("Allow screen recording in System Settings and reopen the app.") }
                    }))
            LabeledContent(tr("Recovery entries"), value: "\(model.journalCount)")
            Button(tr("Restore original windows")) { model.restore() }.disabled(model.busy || model.journalCount == 0)
            if model.state.prefs.diagnosticsEnabled == true {
                LabeledContent(tr("Discovered windows"), value: String(model.windows.count))
                LabeledContent(tr("Displays"), value: String(model.displays.count))
                LabeledContent(tr("Completed operations"), value: String(model.completedOperations))
                LabeledContent(tr("Failed operations"), value: String(model.failedOperations))
            }
            Toggle(
                tr("Show local diagnostics"),
                isOn: Binding(
                    get: { model.state.prefs.diagnosticsEnabled ?? false },
                    set: { value in
                        model.change { $0.prefs.diagnosticsEnabled = value }
                    }))
            Text(tr("Window titles stay on this Mac. Previews are requested only when opened.")).font(.caption)
        case .about:
            LabeledContent("workstack", value: "0.1.0")
            Text(tr("Native window workspaces for macOS"))
            Text(tr("Built with Apple system frameworks. No third-party runtime dependencies."))
        }
    }
    @ViewBuilder var rules: some View {
        Section(tr("Automatic assignment")) {
            TextField(tr("Application bundle identifier"), text: $appID)
            Menu(tr("Choose application")) {
                ForEach(Array(Set(model.windows.map(\.bundleID))).sorted(), id: \.self) { bundle in
                    Button(bundle) { appID = bundle }
                }
            }
            TextField(tr("Title contains (optional)"), text: $titleMatch)
            Picker(tr("Window group"), selection: $target) {
                Text(tr("Choose group")).tag(nil as UUID?)
                ForEach(model.groupList) { Text($0.name).tag(Optional($0.id)) }
            }
            Button(tr("Add rule")) {
                guard let target else { return }
                model.change { $0.prefs.rules.append(AssignmentRule(bundleID: appID, titleContains: titleMatch, group: target)) }
                appID = ""; titleMatch = ""; model.refresh()
            }.disabled(appID.isEmpty || target == nil)
            ForEach(model.state.prefs.rules) { rule in
                HStack {
                    Text(rule.bundleID); Spacer();
                    Button(tr("Remove")) { model.change { $0.prefs.rules.removeAll { $0.id == rule.id } } }
                }
            }
        }
        Section(tr("Excluded windows and applications")) {
            ForEach(model.state.prefs.excludedApps.sorted(), id: \.self) { bundle in
                HStack {
                    Text(bundle); Spacer();
                    Button(tr("Include")) {
                        model.change { $0.prefs.excludedApps.remove(bundle) }; model.refresh()
                    }
                }
            }
            ForEach(Array(model.state.prefs.excludedWindows), id: \.self) { id in
                HStack {
                    Text(model.displayName(id)); Spacer();
                    Button(tr("Include")) {
                        model.change { $0.prefs.excludedWindows.remove(id) }; model.refresh()
                    }
                }
            }
        }
    }
    func transfer(export: Bool) {
        do {
            if export {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "workstack.json"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try LocalFile.write(model.state, to: url)
            } else {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let next = try LocalFile.read(WorkbenchState.self, from: url)
                try next.validate()
                model.change { $0 = next }
                model.refresh()
            }
        } catch { status = tr("Configuration could not be transferred. Check the file and its version.") }
    }
}
