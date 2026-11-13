import Foundation
import Testing
import WorkbenchCore
@testable import WorkbenchApp

@Test func composerPreviewUsesSelectionOrderAndSelectedPreset() {
    let a = UUID(), b = UUID(), c = UUID()
    var draft = GroupComposerDraft()
    draft.name = "Two editors"
    draft.toggle(b)
    draft.toggle(a)
    draft.toggle(c)
    draft.toggle(a)
    draft.preset = .columns
    #expect(draft.group.root?.panes.map(\.tabs) == [[b], [c]])
    draft.preset = .tabs
    #expect(draft.group.root?.panes.map(\.tabs) == [[b, c]])
}

@Test func composerRequiresNamedGroupAndAllSelectedWindowsToStillBeAvailable() {
    let a = UUID(), b = UUID()
    var draft = GroupComposerDraft()
    draft.name = "   "
    draft.toggle(a)
    #expect(!draft.canSubmit(available: [a, b]))
    draft.name = "Work"
    draft.toggle(b)
    #expect(!draft.canSubmit(available: [a]))
    #expect(draft.canSubmit(available: [a, b]))
    draft.toggle(a)
    draft.toggle(b)
    #expect(!draft.canSubmit(available: [a, b]))
}

@Test @MainActor func equalTitlesAndFramesRemainDistinguishableInWindowPickers() {
    func sample(_ id: UUID) -> LiveWindow {
        LiveWindow(
            id: id, bundleID: "fixture.editor", appName: "Editor", title: "Untitled",
            frame: CGRect(x: 64, y: 72, width: 500, height: 300), kind: .normal, minimized: false, fullscreen: false,
            movable: true, resizable: true, minimizable: true, focused: false,
            identity: WindowIdentity(bundleID: "fixture.editor", pid: 1, launched: nil, identifier: nil))
    }
    let a = sample(UUID()), b = sample(UUID())
    #expect(deskWindowDetails([a, b])[a.id] != deskWindowDetails([a, b])[b.id])
    #expect(deskWindowDetails([a, b])[a.id] == deskWindowDetails([b, a])[a.id])
    #expect(deskWindowDetails([a]).isEmpty)
}
