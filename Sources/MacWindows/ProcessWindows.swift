import ApplicationServices
import Foundation
import WorkbenchCore

struct ApplicationInfo: Sendable {
    let pid: pid_t
    let bundle: String
    let name: String
    let launched: Date?
}

struct ProcessSnapshot: Sendable {
    let windows: [LiveWindow]
}

// Its serial queue exclusively owns the mutable AX state. Each application has its own
// queue so a slow application cannot block another application's reads or mutations.
final class ProcessWindows: @unchecked Sendable {
    let info: ApplicationInfo
    private let queue: DispatchQueue
    private let app: Element
    private var ids: [Element: UUID] = [:]
    private var managedMinimized = Set<UUID>()
    private var recoverable = Set<WindowIdentity>()
    private var publishedOrder: [UUID] = []
    private var retiredIdentifiers: Set<String> = []
    private var elements: [UUID: Element] = [:]
    private var safeIdentifiers: [UUID: String] = [:]
    private var observer: AXObserver?
    private var observed: Set<Element> = []
    private let lock = NSLock()
    private var stopped = false
    private var suspended = false

    func suspend(_ value: Bool) {
        lock.withLock { suspended = value }
    }
    private static let fields = [
        kAXTitleAttribute, kAXSubroleAttribute, kAXRoleAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXMinimizedAttribute, "AXFullScreen", kAXIdentifierAttribute,
    ]

    init(_ info: ApplicationInfo) {
        self.info = info
        queue = DispatchQueue(label: "workstack.AX.\(info.pid)", qos: .userInitiated)
        app = Element(raw: AXUIElementCreateApplication(info.pid))
    }

    func authorizeRecovery(_ identities: Set<WindowIdentity>) {
        queue.async { self.recoverable = identities }
    }

    private func recoveryMatches(_ id: UUID, identifier: String?) -> Bool {
        guard let identifier, safeIdentifiers[id] == identifier else { return false }
        return recoverable.contains(
            WindowIdentity(
                bundleID: info.bundle, pid: info.pid, launched: info.launched,
                identifier: identifier))
    }

    func cancel() {
        lock.withLock { stopped = true }
        queue.async { [self] in
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                self.observer = nil
            }
        }
    }

    private func checkActive() throws {
        if lock.withLock({ stopped || suspended }) { throw WindowAccessError.unavailable }
    }

    func perform<T: Sendable>(_ work: @escaping @Sendable (ProcessWindows) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.checkActive()
                    continuation.resume(returning: try work(self))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // The callback's opaque context encodes a PID, with no object lifetime dependency.
    // AX delivers it on the main run loop. The coordinator coalesces all callbacks.
    private func installObserver() {
        guard observer == nil else { return }
        var value: AXObserver?
        let result = AXObserverCreate(
            info.pid,
            { _, _, _, context in
                guard let context else { return }
                let pid = Int(bitPattern: context)
                NotificationCenter.default.post(name: .workbenchAXEvent, object: NSNumber(value: pid))
            }, &value)
        guard result == .success, let value else { return }
        observer = value
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
        for event in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(value, app.raw, event as CFString, UnsafeMutableRawPointer(bitPattern: Int(info.pid)))
        }
    }

    private func observe(_ element: Element) {
        guard let observer, observed.insert(element).inserted else { return }
        for event in [
            kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
        ] {
            AXObserverAddNotification(observer, element.raw, event as CFString, UnsafeMutableRawPointer(bitPattern: Int(info.pid)))
        }
    }

    func scan(frontmost: Bool) throws -> ProcessSnapshot {
        try checkAX(AXUIElementSetMessagingTimeout(app.raw, 0.24))
        let list = (try app.attribute(kAXWindowsAttribute) as? [AXUIElement]) ?? []
        installObserver()
        let focus = frontmost ? try app.child(kAXFocusedWindowAttribute) : nil
        var current: [Element: UUID] = [:]
        var result: [LiveWindow] = []
        for raw in list {
            try checkActive()
            let element = Element(raw: raw)
            guard current[element] == nil else { continue }
            let id = ids[element] ?? UUID()
            do {
                try checkAX(AXUIElementSetMessagingTimeout(raw, 0.24))
                guard let window = try snapshot(element, id: id, focused: focus, reading: false) else { continue }
                current[element] = id
                result.append(window)
                observe(element)
            } catch WindowAccessError.unavailable {
                continue  // The window closed between enumeration and attribute reads.
            }
        }
        // Reorderings and title changes preserve AX equality. If a unique AXIdentifier
        // points at another object during this process lifetime, retire it for recovery.
        let oldIdentifiers = Dictionary(uniqueKeysWithValues: safeIdentifiers.map { ($1, $0) })
        for window in result {
            if let key = window.identity.identifier, let previous = oldIdentifiers[key], previous != window.id {
                retiredIdentifiers.insert(key)
            }
        }
        let present = Set(result.compactMap(\.identity.identifier))
        for key in oldIdentifiers.keys where !present.contains(key) { retiredIdentifiers.insert(key) }
        // Duplicate vendor-supplied identifiers are unsuitable for crash recovery.
        let counts = result.compactMap(\.identity.identifier).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        for index in result.indices {
            if let key = result[index].identity.identifier {
                if counts[key] != 1 { retiredIdentifiers.insert(key) }
                if retiredIdentifiers.contains(key) { result[index].identity.identifier = nil }
            }
        }
        safeIdentifiers = Dictionary(
            uniqueKeysWithValues: result.compactMap { window in
                window.identity.identifier.map { (window.id, $0) }
            })
        for i in result.indices
        where result[i].kind == .dialog && result[i].minimized
            && recoveryMatches(result[i].id, identifier: result[i].identity.identifier)
        { result[i].kind = .normal }
        managedMinimized.formIntersection(current.values)
        ids = current
        elements = Dictionary(uniqueKeysWithValues: current.map { ($1, $0) })
        observed.formIntersection(current.keys)
        let order = Dictionary(uniqueKeysWithValues: publishedOrder.enumerated().map { ($1, $0) })
        result.sort { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
        publishedOrder = result.map(\.id)
        return ProcessSnapshot(windows: result)
    }

    private func snapshot(_ element: Element, id: UUID, focused: Element?, reading: Bool = true) throws -> LiveWindow? {
        var values: CFArray?
        try checkAX(AXUIElementCopyMultipleAttributeValues(element.raw, Self.fields as CFArray, [], &values))
        guard let fields = values as? [AnyObject], fields.count == Self.fields.count,
            let frame = Element.frame(position: fields[3], size: fields[4])
        else { return nil }
        let kind: WindowKind
        switch fields[1] as? String {
        case kAXStandardWindowSubrole: kind = .normal
        case kAXDialogSubrole, kAXSystemDialogSubrole: kind = .dialog
        case kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole: kind = .panel
        default: kind = .other
        }
        let minimized = fields[5] as? Bool ?? false
        // AppKit can temporarily expose AXDialog while miniaturizing a standard
        // NSWindow. Preserve its observed kind only for our own minimize transaction.
        let identifier = (fields[7] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let effectiveKind: WindowKind =
            kind == .dialog && minimized
                && (managedMinimized.contains(id)
                    || (reading && recoveryMatches(id, identifier: identifier)))
            ? .normal : kind
        if !minimized { managedMinimized.remove(id) }
        return try LiveWindow(
            id: id, bundleID: info.bundle, appName: info.name,
            title: fields[0] as? String ?? "", frame: frame, kind: effectiveKind,
            minimized: minimized, fullscreen: fields[6] as? Bool ?? false,
            movable: element.writable(kAXPositionAttribute), resizable: element.writable(kAXSizeAttribute),
            minimizable: element.writable(kAXMinimizedAttribute), focused: element == focused,
            identity: WindowIdentity(bundleID: info.bundle, pid: info.pid, launched: info.launched, identifier: identifier))
    }

    private func element(_ id: UUID) throws -> Element {
        guard let value = elements[id] else { throw WindowAccessError.unavailable }
        return value
    }

    func read(_ id: UUID, frontmost: Bool) throws -> LiveWindow {
        let e = try element(id)
        let focus = frontmost ? try app.child(kAXFocusedWindowAttribute) : nil
        guard var result = try snapshot(e, id: id, focused: focus) else { throw WindowAccessError.unavailable }
        if result.identity.identifier != safeIdentifiers[id] { result.identity.identifier = nil }
        return result
    }

    // Some applications acknowledge a mutation before their event loop commits it.
    // Read back only; repeating a mutation could override a user's intervening action.
    private func verify(_ matches: () throws -> Bool) throws {
        for delay in [0.0, 0.04, 0.08, 0.16, 0.24] {
            try checkActive()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            do {
                if try matches() { return }
            } catch WindowAccessError.busy {
                // The remote run loop may be animating or committing a timed-out write.
                continue
            }
        }
        throw WindowAccessError.verification
    }

    // Recheck mutable remote state on the same queue immediately before a write.
    // A process may enter full screen, hide, minimize or replace its window at any time.
    func writableWindow(_ id: UUID, allowMinimized: Bool = false) throws -> Element {
        try checkActive()
        let e = try element(id)
        let keys = [kAXRoleAttribute, kAXSubroleAttribute, "AXFullScreen", kAXMinimizedAttribute, kAXIdentifierAttribute]
        var values: CFArray?
        try checkAX(AXUIElementCopyMultipleAttributeValues(e.raw, keys as CFArray, [], &values))
        guard let state = values as? [AnyObject], state.count == keys.count else { throw WindowAccessError.unsupported }
        let minimized = state[3] as? Bool
        let restoring =
            allowMinimized && minimized == true && state[1] as? String == kAXDialogSubrole
            && (managedMinimized.contains(id) || recoveryMatches(id, identifier: state[4] as? String))
        guard state[0] as? String == kAXWindowRole,
            state[1] as? String == kAXStandardWindowSubrole || restoring,
            state[2] as? Bool != true, allowMinimized || minimized == false,
            try app.attribute(kAXHiddenAttribute) as? Bool != true
        else { throw WindowAccessError.unsupported }
        return e
    }

    func minimize(_ id: UUID, flag: Bool) throws {
        let e = try writableWindow(id, allowMinimized: true)
        if try e.attribute(kAXMinimizedAttribute) as? Bool == flag { return }
        guard try e.writable(kAXMinimizedAttribute) else { throw WindowAccessError.unsupported }
        do { try e.set(kAXMinimizedAttribute, flag ? kCFBooleanTrue : kCFBooleanFalse) } catch WindowAccessError.busy {
            // A timed-out AX setter may already have committed, especially during
            // the Dock animation. Read back without issuing a second mutation.
        }
        try verify { try e.attribute(kAXMinimizedAttribute) as? Bool == flag }
        if flag { managedMinimized.insert(id) } else { managedMinimized.remove(id) }
    }

    func frame(_ id: UUID, target: CGRect) throws {
        let e = try writableWindow(id)
        guard let initial = try e.frame() else { throw WindowAccessError.unsupported }
        if initial.roughlyEquals(target) { return }
        let move = abs(initial.minX - target.minX) > 2 || abs(initial.minY - target.minY) > 2
        let resize = abs(initial.width - target.width) > 2 || abs(initial.height - target.height) > 2
        if move, try !e.writable(kAXPositionAttribute) { throw WindowAccessError.unsupported }
        if resize, try !e.writable(kAXSizeAttribute) { throw WindowAccessError.unsupported }
        var point = target.origin
        var size = target.size
        guard let position = AXValueCreate(.cgPoint, &point), let extent = AXValueCreate(.cgSize, &size) else {
            throw WindowAccessError.invalidFrame
        }
        if move { try e.set(kAXPositionAttribute, position) }
        if resize { try e.set(kAXSizeAttribute, extent) }
        // The old size may have constrained the initial move against a screen edge.
        if move, resize, let after = try e.frame(), abs(after.minX - target.minX) > 2 || abs(after.minY - target.minY) > 2 {
            try e.set(kAXPositionAttribute, position)
        }
        try verify { try e.frame()?.roughlyEquals(target) == true }
    }

    func raise(_ id: UUID) throws {
        let e = try writableWindow(id)
        // Cooperative NSRunningApplication activation can decline a request from a
        // background manager. AXFrontmost is publicly writable with AX permission.
        if try app.attribute(kAXFrontmostAttribute) as? Bool != true {
            guard try app.writable(kAXFrontmostAttribute) else { throw WindowAccessError.unsupported }
            try app.set(kAXFrontmostAttribute, kCFBooleanTrue)
            try verify { try app.attribute(kAXFrontmostAttribute) as? Bool == true }
        }
        if try e.writable(kAXMainAttribute) { try e.set(kAXMainAttribute, kCFBooleanTrue) }
        try checkAX(AXUIElementPerformAction(e.raw, kAXRaiseAction as CFString))
        try verify { try app.child(kAXFocusedWindowAttribute) == e }
    }
}

extension Notification.Name {
    static let workbenchAXEvent = Notification.Name("workstack.remoteWindowEvent")
}
