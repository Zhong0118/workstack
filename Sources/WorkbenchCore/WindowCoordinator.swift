import Foundation

@MainActor
public protocol WindowControl: AnyObject {
    func read(_ id: UUID) async throws -> LiveWindow
    func focus(_ id: UUID) async throws
    func setFrame(_ frame: CGRect, for id: UUID) async throws
    func setMinimized(_ flag: Bool, for id: UUID) async throws
}

public enum WindowCommand: Sendable {
    case place(UUID, CGRect)
    case conceal(UUID)
    case reveal(UUID)
    case raise(UUID)
    public var member: UUID {
        switch self {
        case .place(let id, _), .conceal(let id), .reveal(let id), .raise(let id): id
        }
    }
}

public enum ControlError: Error { case unavailable, unexpectedFrame, recoveryRequired }

/// The caller serializes transactions. The on-disk lease precedes each reversible AX write.
@MainActor
public final class WindowCoordinator {
    public private(set) var journal: RecoveryJournal
    public private(set) var lastAttempt: WindowCommand?
    private let controller: any WindowControl
    private let persist: (RecoveryJournal) throws -> Void
    public init(controller: any WindowControl, journal: RecoveryJournal, persist: @escaping (RecoveryJournal) throws -> Void) {
        self.controller = controller
        self.journal = journal
        self.persist = persist
    }

    private func record(_ lease: WindowLease?, for member: UUID) throws {
        var next = journal
        next.entries[member] = lease
        try persist(next)
        journal = next
    }

    public func perform(_ commands: [WindowCommand], binding: [UUID: UUID], unique: Set<UUID>) async throws {
        var before: [(member: UUID, live: LiveWindow, lease: WindowLease?, command: WindowCommand)] = []
        do {
            for command in commands {
                lastAttempt = command
                let member = command.member
                guard let runtime = binding[member] else { continue }
                let live = try await controller.read(runtime)
                guard live.kind == .normal, !live.fullscreen else { continue }
                let previous = journal.entries[member]
                guard previous == nil || previous?.identity == live.identity else { throw ControlError.recoveryRequired }
                var lease = previous ?? WindowLease(identity: live.identity)
                switch command {
                case .place(_, let target):
                    guard live.movable, live.resizable, !live.minimized, !live.frame.roughlyEquals(target) else { continue }
                    if lease.expectedFrame?.roughlyEquals(live.frame) != true { lease.originalFrame = live.frame }
                    lease.expectedFrame = target
                    try record(lease, for: member)
                    before.append((member, live, previous, command))
                    try await controller.setFrame(target, for: runtime)
                    let actual = try await controller.read(runtime)
                    guard actual.frame.roughlyEquals(target, tolerance: 3) else { throw ControlError.unexpectedFrame }
                case .conceal:
                    guard live.minimizable, !live.minimized, unique.contains(member), live.identity.permitsRecovery else {
                        continue
                    }
                    lease.minimizedByUs = true
                    try record(lease, for: member)
                    before.append((member, live, previous, command))
                    try await controller.setMinimized(true, for: runtime)
                case .reveal:
                    guard lease.minimizedByUs else { continue }
                    if live.minimized {
                        before.append((member, live, previous, command))
                        try await controller.setMinimized(false, for: runtime)
                    }
                    lease.minimizedByUs = false
                    try record(lease.originalFrame == nil ? nil : lease, for: member)
                case .raise:
                    if !live.minimized { try await controller.focus(runtime) }
                }
            }
        } catch {
            // Undo only writes in this invocation. Keep durable recovery evidence on rollback failure.
            for item in before.reversed() {
                do {
                    let now = try await controller.read(item.live.id)
                    guard now.identity == item.live.identity, !now.fullscreen else { continue }
                    switch item.command {
                    case .place(_, let target):
                        // An AX frame write can commit position and size separately. Roll back
                        // those components only while they still match either side of our write.
                        let original = item.live.frame
                        let positionKnown = [original.origin, target.origin].contains { point in
                            abs(now.frame.minX - point.x) <= 3 && abs(now.frame.minY - point.y) <= 3
                        }
                        let sizeKnown = [original.size, target.size].contains { size in
                            abs(now.frame.width - size.width) <= 3 && abs(now.frame.height - size.height) <= 3
                        }
                        if !now.minimized, positionKnown, sizeKnown, !now.frame.roughlyEquals(original) {
                            try await controller.setFrame(original, for: now.id)
                        }
                    case .conceal, .reveal:
                        if now.minimized != item.live.minimized {
                            try await controller.setMinimized(item.live.minimized, for: now.id)
                        }
                    case .raise: break
                    }
                    try record(item.lease, for: item.member)
                } catch { continue }
            }
            throw error
        }
    }

    /// An observed user unminimize ends our claim on the minimized state.
    public func observeVisible(_ member: UUID, identity: WindowIdentity) throws {
        guard var lease = journal.entries[member], lease.minimizedByUs, lease.identity == identity else { return }
        lease.minimizedByUs = false
        try record(lease.originalFrame == nil ? nil : lease, for: member)
    }

    public func restore(_ member: UUID, runtime: UUID, safeAreas: [CGRect]) async throws {
        guard let lease = journal.entries[member] else { return }
        let live = try await controller.read(runtime)
        guard live.identity == lease.identity, !live.fullscreen, live.kind == .normal else { throw ControlError.unavailable }
        if live.minimized && lease.minimizedByUs { try await controller.setMinimized(false, for: runtime) }
        if (!live.minimized || lease.minimizedByUs), var original = lease.originalFrame,
            lease.expectedFrame?.roughlyEquals(live.frame, tolerance: 3) == true, live.resizable, live.movable
        {
            if !safeAreas.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(original) }) {
                guard
                    let area = safeAreas.max(by: {
                        intersectionArea($0, original) < intersectionArea($1, original)
                    })
                else { throw ControlError.unavailable }
                original.size = CGSize(width: min(area.width, original.width), height: min(area.height, original.height))
                original.origin = CGPoint(
                    x: max(area.minX, min(original.minX, area.maxX - original.width)),
                    y: max(area.minY, min(original.minY, area.maxY - original.height)))
            }
            try await controller.setFrame(original, for: runtime)
        }
        try record(nil, for: member)
    }
}

private func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    return i.isNull ? 0 : i.width * i.height
}
