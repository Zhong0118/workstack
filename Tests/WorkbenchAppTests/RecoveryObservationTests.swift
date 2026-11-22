import Foundation
import Observation
import Testing
import WorkbenchCore
import os
@testable import WorkbenchApp

@Test @MainActor func recoveryCountNotifiesOpenSettingsWhenUserRestoresAWindow() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = AppTestWindows(), id = system.add()
    let model = Workbench(directory: directory, controller: system)
    func publish() {
        model.update(Array(system.windows.values), permission: true, screens: [AppTestWindows.screen])
    }
    publish()
    try await model.execute([.conceal(id)])
    publish()
    let changed = OSAllocatedUnfairLock(initialState: false)
    let count = withObservationTracking {
        model.journalCount
    } onChange: {
        changed.withLock { $0 = true }
    }
    #expect(count == 1)
    try await system.setMinimized(false, for: id)
    publish()
    #expect(model.journalCount == 0)
    #expect(changed.withLock { $0 })
}
