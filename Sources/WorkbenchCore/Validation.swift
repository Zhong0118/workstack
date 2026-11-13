import Foundation

public extension WorkbenchState {
    var memberIDs: [UUID] { workspaces.flatMap { $0.groups.flatMap(\.memberIDs) } }

    func validate() throws {
        guard version == 1 else { throw StorageError.unsupportedVersion }
        var objectIDs = Set<UUID>()
        var members = Set<UUID>()
        func identifier(_ id: UUID) throws {
            guard objectIDs.insert(id).inserted else { throw StorageError.invalidConfiguration }
        }
        func node(_ value: LayoutNode, template: Bool, depth: Int) throws {
            guard depth <= 64 else { throw StorageError.invalidConfiguration }
            switch value {
            case let .pane(id, tabs, active):
                try identifier(id)
                guard active == nil || tabs.contains(active!), !template || tabs.isEmpty else {
                    throw StorageError.invalidConfiguration
                }
                for tab in tabs {
                    guard members.insert(tab).inserted else { throw StorageError.invalidConfiguration }
                }
            case let .split(id, _, ratio, first, second):
                try identifier(id)
                guard ratio.isFinite, ratio > 0, ratio < 1 else { throw StorageError.invalidConfiguration }
                try node(first, template: template, depth: depth + 1)
                try node(second, template: template, depth: depth + 1)
            }
        }
        func group(_ g: WindowGroup, template: Bool) throws {
            try identifier(g.id)
            if let root = g.root { try node(root, template: template, depth: 0) }
            for member in g.floating {
                guard !template, members.insert(member).inserted else { throw StorageError.invalidConfiguration }
            }
        }
        guard prefs.gap.isFinite, (0...40).contains(prefs.gap),
            activeID == nil || workspaces.contains(where: { $0.id == activeID })
        else { throw StorageError.invalidConfiguration }
        let chords =
            [KeyChord(key: prefs.shortcutKey, modifiers: prefs.shortcutModifiers)]
            + Array((prefs.additionalShortcuts ?? [:]).values)
        guard chords.allSatisfy(\.isValid), Set(chords).count == chords.count,
            prefs.additionalShortcuts?.keys.allSatisfy({ ["2", "3", "4"].contains($0) }) != false
        else {
            throw StorageError.invalidConfiguration
        }
        for rect in Array(groupAreas.values) + (floatingFrames ?? [:]).values.map(\.relative) {
            guard rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite, rect.width > 0, rect.height > 0
            else {
                throw StorageError.invalidConfiguration
            }
        }
        for ws in workspaces {
            try identifier(ws.id)
            for g in ws.groups { try group(g, template: false) }
        }
        for t in templates { try group(t, template: true) }
    }
}
