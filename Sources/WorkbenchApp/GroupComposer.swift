import SwiftUI
import WorkbenchCore

struct GroupComposerDraft {
    var name = ""
    var preset: LayoutPreset = .tabs
    private(set) var selection: [UUID] = []

    mutating func toggle(_ id: UUID) {
        if let index = selection.firstIndex(of: id) { selection.remove(at: index) } else { selection.append(id) }
    }

    func canSubmit(available: Set<UUID>) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selection.isEmpty
            && selection.allSatisfy(available.contains)
    }

    var group: DeskGroup {
        var group = DeskGroup(name: name, floating: selection)
        group.apply(preset)
        return group
    }
}

struct GroupComposer: View {
    let onCreated: (UUID) -> Void
    @State private var workspace: UUID
    @Environment(Workbench.self) var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = GroupComposerDraft()
    @State private var filter = ""
    @State private var submitting = false
    @State private var error: String?

    init(request: DeskComposeRequest, onCreated: @escaping (UUID) -> Void) {
        self.onCreated = onCreated
        _workspace = State(initialValue: request.workspace)
        var draft = GroupComposerDraft()
        if let member = request.member { draft.toggle(member) }
        _draft = State(initialValue: draft)
    }

    var body: some View {
        let candidates = model.windows.filter { $0.kind == .normal && !$0.fullscreen }
        let available = Set(candidates.map(\.id))
        let details = deskWindowDetails(candidates)
        let owners = Dictionary(uniqueKeysWithValues: model.groupList.flatMap { group in group.memberIDs.map { ($0, group.name) } })
        let visible = candidates.filter { filter.isEmpty || ($0.appName + " " + $0.title).localizedCaseInsensitiveContains(filter) }
        let stale = draft.selection.filter { !available.contains($0) }
        VStack(alignment: .leading, spacing: model.state.prefs.compact ? 9 : 14) {
            Text(d("New window group")).font(.title2.bold())
            Picker(d("Workspace"), selection: $workspace) {
                ForEach(model.state.workspaces) { space in Text(space.name).tag(space.id) }
            }.disabled(submitting)
            TextField(d("Name"), text: $draft.name).textFieldStyle(.roundedBorder).disabled(submitting)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(d("Filter windows"), text: $filter).textFieldStyle(.roundedBorder)
                    if !model.trusted {
                        WindowPermissionHelp()
                    }
                    List {
                        ForEach(visible) { w in
                            Toggle(isOn: Binding(get: { draft.selection.contains(w.id) }, set: { _ in draft.toggle(w.id) })) {
                                HStack(spacing: 7) {
                                    DeskIcon(id: w.id, size: 21)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(model.displayName(w.id)).lineLimit(1)
                                        Text(
                                            [details[w.id] ?? w.appName, owners[w.id]].compactMap { $0 }.joined(
                                                separator: " · ")
                                        )
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        if !w.movable || !w.resizable {
                                            Text(
                                                [w.movable ? nil : d("Fixed position"), w.resizable ? nil : d("Fixed size")]
                                                    .compactMap { $0 }.joined(separator: " · ")
                                            ).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }.help(model.displayName(w.id) + "\n" + (details[w.id] ?? w.appName))
                            }.toggleStyle(.checkbox)
                        }
                        ForEach(stale, id: \.self) { id in
                            Button {
                                draft.toggle(id)
                            } label: {
                                Label(
                                    d("Remove unavailable selection") + " · " + model.displayName(id), systemImage: "minus.circle")
                            }.buttonStyle(.borderless)
                        }
                    }.listStyle(.bordered)
                        .overlay {
                            if visible.isEmpty, stale.isEmpty {
                                Text(
                                    d(
                                        !model.trusted
                                            ? "Window discovery requires Accessibility"
                                            : filter.isEmpty ? "No eligible windows" : "No matching windows")
                                )
                                .foregroundStyle(.secondary).allowsHitTesting(false)
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Picker(d("Layout"), selection: $draft.preset) {
                        ForEach(LayoutPreset.allCases, id: \.self) { p in Text(d(p.rawValue)).tag(p) }
                    }
                    let preview = draft.group
                    if draft.preset == .free {
                        Label(d("Keep current window positions"), systemImage: "macwindow.on.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 108)
                    } else {
                        DeskPreview(group: preview).frame(height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    Text(d("Selected windows") + " · " + String(draft.selection.count)).font(.headline)
                    if model.trusted {
                        Text(d("Available windows") + " · " + String(visible.count)).font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(draft.selection.enumerated()), id: \.element) { index, id in
                                Text("\(index + 1). " + model.displayName(id)).font(.callout).lineLimit(1)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(width: 190)
            }.disabled(submitting)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
            HStack {
                if draft.selection.isEmpty {
                    Button(d("Create empty group")) { createEmpty() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy || submitting)
                }
                if submitting { ProgressView().controlSize(.small) }
                Spacer()
                Button(d("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                Button(d("Create and apply")) { submit() }.keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSubmit(available: available) || !model.trusted || model.busy || submitting)
            }
        }.padding(20).frame(width: 590, height: model.state.prefs.compact ? 410 : 465)
            .interactiveDismissDisabled(submitting)
            .animation(reduceMotion || !model.state.prefs.enableAnimations ? nil : .easeInOut(duration: 0.15), value: draft.preset)
    }

    private func createEmpty() {
        guard draft.selection.isEmpty, !model.busy, !submitting,
            let index = model.state.workspaces.firstIndex(where: { $0.id == workspace })
        else { return }
        var empty = draft.group
        empty.name = empty.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !empty.name.isEmpty else { return }
        switch model.change({ $0.workspaces[index].groups.append(empty) }) {
        case .success: onCreated(empty.id); dismiss()
        case let .failure(failure): error = model.actionMessage(failure)
        }
    }

    private func submit() {
        guard !submitting, !model.busy else { return }
        submitting = true
        error = nil
        Task {
            let result = await model.createAndApplyGroup(
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), workspace: workspace,
                members: draft.selection, preset: draft.preset)
            submitting = false
            switch result {
            case let .success(id): onCreated(id); dismiss()
            case let .failure(failure): error = model.actionMessage(failure)
            }
        }
    }
}
