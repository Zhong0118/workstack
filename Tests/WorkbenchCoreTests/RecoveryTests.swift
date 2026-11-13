import Foundation
import Testing
@testable import WorkbenchCore

@MainActor private final class FakeWindows: WindowControl {
    var windows: [UUID: LiveWindow] = [:]
    var fail: UUID?
    func add(stable: Bool = true, minimized: Bool = false) -> UUID {
        let id = UUID()
        let identity = WindowIdentity(
            bundleID: "test.fixture", pid: 123, launched: Date(), identifier: stable ? id.uuidString : nil)
        windows[id] = LiveWindow(
            id: id, bundleID: identity.bundleID, appName: "Fixture", title: "same",
            frame: CGRect(x: 10, y: 40, width: 250, height: 180),
            kind: .normal, minimized: minimized, fullscreen: false, movable: true, resizable: true, minimizable: true,
            focused: false, identity: identity)
        return id
    }
    func read(_ id: UUID) async throws -> LiveWindow {
        guard let window = windows[id] else { throw ControlError.unavailable }
        return window
    }
    func focus(_ id: UUID) async throws { windows[id]?.focused = true }
    func setFrame(_ frame: CGRect, for id: UUID) async throws {
        if fail == id { throw ControlError.unavailable }
        windows[id]?.frame = frame
    }
    func setMinimized(_ flag: Bool, for id: UUID) async throws { windows[id]?.minimized = flag }
}

@Test @MainActor func rollbackAndWriteAhead() async throws {
    let sys = FakeWindows(), a = sys.add(), b = sys.add()
    let original = try await sys.read(a).frame
    let target = CGRect(x: 0, y: 0, width: 800, height: 600)
    let disk = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: disk) }
    let coord = WindowCoordinator(controller: sys, journal: RecoveryJournal()) { try LocalFile.write($0, to: disk) }
    sys.fail = b
    await #expect(throws: ControlError.self) {
        try await coord.perform([.place(a, target), .place(b, target)], binding: [a: a, b: b], unique: [a, b])
    }
    #expect(sys.windows[a]?.frame == original)
    #expect(coord.journal.entries.isEmpty)
    #expect(try LocalFile.read(RecoveryJournal.self, from: disk).entries.isEmpty)
    let cannotWrite = WindowCoordinator(controller: sys, journal: RecoveryJournal()) { _ in throw StorageError.invalidConfiguration
    }
    await #expect(throws: StorageError.self) { try await cannotWrite.perform([.conceal(a)], binding: [a: a], unique: [a]) }
    #expect(sys.windows[a]?.minimized == false)
}

@Test @MainActor func minimizationOwnershipAndRecoveryIdentity() async throws {
    let sys = FakeWindows(), a = sys.add(), b = sys.add(minimized: true), c = sys.add(stable: false)
    var disk = RecoveryJournal()
    let coord = WindowCoordinator(controller: sys, journal: disk) { disk = $0 }
    let binding = [a: a, b: b, c: c]
    try await coord.perform([.conceal(b), .conceal(c), .conceal(a)], binding: binding, unique: [a, b, c])
    #expect(Set(disk.entries.keys) == [a])
    #expect(sys.windows[b]?.minimized == true && sys.windows[c]?.minimized == false)
    let restart = WindowCoordinator(controller: sys, journal: disk) { disk = $0 }
    await #expect(throws: ControlError.self) { try await restart.restore(a, runtime: b, safeAreas: []) }
    #expect(sys.windows[b]?.minimized == true)
    try await restart.restore(a, runtime: a, safeAreas: [])
    #expect(sys.windows[a]?.minimized == false && disk.entries.isEmpty)
}

@Test @MainActor func externalMoveWinsAndDisconnectedDisplayIsClamped() async throws {
    let sys = FakeWindows(), id = sys.add()
    sys.windows[id]?.frame.origin.x = -1900
    let coord = WindowCoordinator(controller: sys, journal: RecoveryJournal()) { _ in }
    let target = CGRect(x: 0, y: 30, width: 900, height: 600)
    try await coord.perform([.place(id, target)], binding: [id: id], unique: [id])
    try await coord.restore(id, runtime: id, safeAreas: [target])
    #expect(target.contains(sys.windows[id]!.frame))
    try await coord.perform([.place(id, target)], binding: [id: id], unique: [id])
    let manual = CGRect(x: 120, y: 80, width: 400, height: 350)
    sys.windows[id]?.frame = manual
    try await coord.restore(id, runtime: id, safeAreas: [target])
    #expect(sys.windows[id]?.frame == manual)
}

@Test func rejectNewerConfigurationVersion() throws {
    var state = WorkbenchState()
    state.version = 2
    #expect(throws: StorageError.self) { try state.validate() }
}
