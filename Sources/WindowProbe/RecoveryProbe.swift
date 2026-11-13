import AppKit
import MacWindows
import WorkbenchCore

@MainActor enum RecoveryProbe {
    static func run(_ url: URL) async throws {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "local.windowworkbench.integration-fixture",
            bundle.executableURL?.lastPathComponent == "window-probe"
        else { throw WindowAccessError.unsupported }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--fixture", "2"]
        let fixture = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        defer { fixture.terminate() }
        var first: [LiveWindow] = []
        let original = MacWindows()
        original.onChange = { first = $0.filter { $0.identity.pid == fixture.processIdentifier } }
        original.start()
        defer { original.stop() }
        try await until { first.count == 2 }
        let target = first[0], sibling = first[1]
        guard target.identity.permitsRecovery, sibling.identity.permitsRecovery,
            target.identity != sibling.identity
        else { throw WindowAccessError.verification }
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: journal) }
        let owner = WindowCoordinator(controller: original, journal: RecoveryJournal()) { try LocalFile.write($0, to: journal) }
        try await owner.perform([.conceal(target.id)], binding: [target.id: target.id], unique: [target.id])
        guard try await original.read(target.id).minimized,
            try await !original.read(sibling.id).minimized
        else { throw WindowAccessError.verification }
        original.stop()
        let persisted = try LocalFile.read(RecoveryJournal.self, from: journal)
        let fresh = MacWindows()
        var second: [LiveWindow] = []
        fresh.onChange = { second = $0.filter { $0.identity.pid == fixture.processIdentifier } }
        fresh.authorizeRecovery(persisted.entries.values.filter(\.minimizedByUs).map(\.identity))
        fresh.start()
        defer { fresh.stop() }
        try await until { second.count == 2 }
        guard let recovered = second.first(where: { $0.identity == target.identity }), recovered.id != target.id,
            recovered.kind == .normal, recovered.minimized, let other = second.first(where: { $0.identity == sibling.identity })
        else { throw WindowAccessError.verification }
        let restore = WindowCoordinator(controller: fresh, journal: persisted) { try LocalFile.write($0, to: journal) }
        try await restore.restore(target.id, runtime: recovered.id, safeAreas: MacDisplay.all.map(\.frame))
        let actual = try await fresh.read(recovered.id)
        let adjacent = try await fresh.read(other.id)
        guard !actual.minimized, !adjacent.minimized, actual.frame.roughlyEquals(target.frame),
            adjacent.frame.roughlyEquals(sibling.frame), restore.journal.entries.isEmpty
        else { throw WindowAccessError.verification }
    }

    private static func until(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition() {
            guard clock.now < deadline else { throw WindowAccessError.unavailable }
            try await Task.sleep(for: .milliseconds(60))
        }
    }
}
