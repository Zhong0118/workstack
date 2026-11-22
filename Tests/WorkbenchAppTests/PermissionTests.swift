import Foundation
import Testing
@testable import WorkbenchApp

@Test @MainActor func firstRenderReadsPermissionBeforeWindowDiscoveryStarts() {
    let model = Workbench(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    #expect(model.trusted == model.backend.trusted)
}

@Test @MainActor func revokedPermissionDiscardsAnAlreadyQueuedWindowSnapshot() {
    let system = AppTestWindows()
    let id = system.add()
    let model = Workbench(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), controller: system)
    let snapshot = Array(system.windows.values)
    model.update(snapshot, permission: true, screens: [AppTestWindows.screen])
    #expect(model.bindings[id] == id)
    model.update(snapshot, permission: false, screens: [AppTestWindows.screen])
    #expect(!model.trusted)
    #expect(model.windows.isEmpty)
    #expect(model.bindings.isEmpty)
    model.update(snapshot, permission: true, screens: [AppTestWindows.screen])
    #expect(model.windows.map(\.id) == [id])
}
