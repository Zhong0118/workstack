import Foundation
import WorkbenchCore

@MainActor final class AppTestWindows: WindowControl {
    var windows: [UUID: LiveWindow] = [:]
    var minimumSizes: [UUID: CGSize] = [:]
    var failFocus: UUID?
    var failMinimize: UUID?
    var focusedIDs: [UUID] = []

    static let screen = DisplayArea(id: "test", name: "Test", frame: CGRect(x: 0, y: 0, width: 1200, height: 900))

    func add(minimized: Bool = false) -> UUID {
        let id = UUID()
        windows[id] = LiveWindow(
            id: id, bundleID: "test.app", appName: "Test", title: "Test", frame: CGRect(x: 20, y: 40, width: 320, height: 260),
            kind: .normal, minimized: minimized, fullscreen: false, movable: true, resizable: true, minimizable: true,
            focused: false, identity: WindowIdentity(bundleID: "test.app", pid: 123, launched: Date(), identifier: id.uuidString))
        return id
    }

    func read(_ id: UUID) async throws -> LiveWindow {
        guard let live = windows[id] else { throw ControlError.unavailable }
        return live
    }

    func orderFront(_ id: UUID) async throws {}
    func focus(_ id: UUID) async throws {
        if failFocus == id { throw ControlError.unavailable }
        for key in windows.keys { windows[key]?.focused = key == id }
        focusedIDs.append(id)
    }
    func setFrame(_ frame: CGRect, for id: UUID) async throws {
        var applied = frame
        if let minimum = minimumSizes[id] {
            applied.size = CGSize(width: max(frame.width, minimum.width), height: max(frame.height, minimum.height))
        }
        windows[id]?.frame = applied
    }
    func setMinimized(_ flag: Bool, for id: UUID) async throws {
        if failMinimize == id { throw ControlError.unavailable }
        windows[id]?.minimized = flag
    }
}
