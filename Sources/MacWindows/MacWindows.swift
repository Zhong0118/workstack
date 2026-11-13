import AppKit
import ApplicationServices
import WorkbenchCore

@MainActor public final class MacWindows: WindowControl {
    public var onChange: (([LiveWindow]) -> Void)?
    public var trusted: Bool { AXIsProcessTrusted() }
    private var workers: [pid_t: ProcessWindows] = [:]
    private var snapshots: [pid_t: [LiveWindow]] = [:]
    private var owners: [UUID: pid_t] = [:]
    private var inFlight = Set<pid_t>()
    private var dirty = Set<pid_t>()
    private var delayed: [pid_t: Task<Void, Never>] = [:]
    private var recoverable = Set<WindowIdentity>()
    private var failures: [pid_t: Int] = [:]
    private var publishTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var subscriptions: [(NotificationCenter, NSObjectProtocol)] = []
    private var suspensions = Set<Notification.Name>()
    private var sleeping: Bool { !suspensions.isEmpty }
    private var running = false
    private var lastFrontmost: pid_t?
    private var allowedApplications: [NSRunningApplication]?

    public init(allowedApplications: [NSRunningApplication]? = nil) {
        self.allowedApplications = allowedApplications
    }

    /// A fixture session starts with an empty allowlist. Bind it to its freshly launched processes once.
    public func allowFixtures(_ applications: [NSRunningApplication]) {
        guard allowedApplications?.isEmpty == true else { return }
        allowedApplications = applications
        refresh()
    }

    private func isAllowed(_ app: NSRunningApplication) -> Bool {
        allowedApplications?.contains {
            !$0.isTerminated && $0.processIdentifier == app.processIdentifier
                && $0.launchDate != nil && $0.launchDate == app.launchDate
        } ?? true
    }

    public func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    public func start() {
        guard !running else { return }
        running = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            listen(workspace, name)
        }
        listen(.default, NSApplication.didChangeScreenParametersNotification)
        listen(.default, .workbenchAXEvent)
        refresh()
        // Cover AX implementations that omit notifications and notice a TCC change.
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self else { return }
                self.reconcile(force: false)
            }
        }
    }

    public func stop() {
        running = false
        suspensions.removeAll()
        subscriptions.forEach { $0.0.removeObserver($0.1) }
        subscriptions.removeAll()
        heartbeat?.cancel()
        heartbeat = nil
        publishTask?.cancel()
        publishTask = nil
        clear()
    }

    private func listen(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
            let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = (event.object as? NSNumber)?.int32Value ?? app?.processIdentifier
            let launched = app?.launchDate
            MainActor.assumeIsolated { self?.handle(name, pid: pid, launched: launched) }
        }
        subscriptions.append((center, token))
    }

    private func handle(_ name: Notification.Name, pid: pid_t?, launched: Date?) {
        guard running else { return }
        switch name {
        case NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification:
            suspensions.insert(name)
            for worker in workers.values { worker.suspend(true) }
        case NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification:
            let reason =
                name == NSWorkspace.didWakeNotification
                ? NSWorkspace.willSleepNotification
                : (name == NSWorkspace.screensDidWakeNotification
                    ? NSWorkspace.screensDidSleepNotification : NSWorkspace.sessionDidResignActiveNotification)
            suspensions.remove(reason)
            if !sleeping {
                for worker in workers.values { worker.suspend(false) }
                refresh()
            }
        case NSWorkspace.activeSpaceDidChangeNotification, NSApplication.didChangeScreenParametersNotification:
            refresh()
        case .workbenchAXEvent:
            if let pid { schedule(pid) }
        default:
            guard let pid else { return }
            if name == NSWorkspace.didTerminateApplicationNotification {
                if workers[pid]?.info.launched == launched { remove(pid); publish() }
            } else if !sleeping, trusted, let app = NSRunningApplication(processIdentifier: pid) {
                if name == NSWorkspace.didActivateApplicationNotification {
                    if let old = lastFrontmost { schedule(old) }
                    lastFrontmost = pid
                }
                discover(app)
                schedule(pid)
            }
        }
    }

    /// Only identities from durable, unreleased minimization leases are eligible.
    /// Repeated identities in the journal are ambiguous even if only one window is visible.
    public func authorizeRecovery(_ entries: [WindowIdentity]) {
        let next = Set(
            Dictionary(grouping: entries.filter(\.permitsRecovery), by: { $0 })
                .compactMap { $1.count == 1 ? $0 : nil })
        guard next != recoverable else { return }
        let changed = Set(next.symmetricDifference(recoverable).map(\.pid))
        recoverable = next
        for pid in changed {
            workers[pid]?.authorizeRecovery(next.filter { $0.pid == pid })
            schedule(pid)
        }
    }

    public func refresh() { reconcile(force: true) }

    private func reconcile(force: Bool) {
        guard running, !sleeping else { return }
        guard trusted else {
            clear()
            publish()
            return
        }
        let apps = NSWorkspace.shared.runningApplications.filter(eligible)
        let active = Set(apps.map(\.processIdentifier))
        for pid in Array(workers.keys) where !active.contains(pid) { remove(pid) }
        lastFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in apps {
            discover(app)
            // A heartbeat never cuts short an unresponsive process's backoff.
            schedule(app.processIdentifier, immediate: force)
        }
        publish()
    }

    private func eligible(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier > 0 && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && isAllowed(app) && app.activationPolicy != .prohibited && !app.isTerminated
    }

    private func discover(_ app: NSRunningApplication) {
        guard eligible(app) else { return }
        let pid = app.processIdentifier
        if let old = workers[pid] {
            if old.info.launched == app.launchDate && old.info.bundle == (app.bundleIdentifier ?? "") { return }
            remove(pid)
        }
        workers[pid] = ProcessWindows(
            ApplicationInfo(
                pid: pid, bundle: app.bundleIdentifier ?? "",
                name: app.localizedName ?? "", launched: app.launchDate))
        workers[pid]?.authorizeRecovery(recoverable.filter { $0.pid == pid })
    }

    private func clear() {
        for pid in Array(workers.keys) { remove(pid) }
        lastFrontmost = nil
    }

    private func remove(_ pid: pid_t) {
        delayed.removeValue(forKey: pid)?.cancel()
        workers.removeValue(forKey: pid)?.cancel()
        for window in snapshots.removeValue(forKey: pid) ?? [] { owners.removeValue(forKey: window.id) }
        inFlight.remove(pid)
        failures.removeValue(forKey: pid)
        dirty.remove(pid)
    }

    private func schedule(_ pid: pid_t, immediate: Bool = false) {
        guard running, !sleeping, let worker = workers[pid] else { return }
        if inFlight.contains(pid) { dirty.insert(pid); return }
        if delayed[pid] != nil { return }
        let attempts = failures[pid] ?? 0
        let delay = attempts > 0 ? min(12_000, 300 * (1 << min(attempts, 6))) : (immediate ? 0 : 90)
        delayed[pid] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled, let self, self.workers[pid] === worker else { return }
            self.delayed.removeValue(forKey: pid)
            self.scan(worker)
        }
    }

    private func scan(_ worker: ProcessWindows) {
        let pid = worker.info.pid
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        inFlight.insert(pid)
        Task { [weak self] in
            let result: Result<ProcessSnapshot, Error>
            do { result = .success(try await worker.perform { try $0.scan(frontmost: front) }) } catch { result = .failure(error) }
            guard let self, self.workers[pid] === worker else { return }
            self.inFlight.remove(pid)
            switch result {
            case .success(let snapshot):
                self.failures.removeValue(forKey: pid)
                for old in self.snapshots[pid] ?? [] { self.owners.removeValue(forKey: old.id) }
                self.snapshots[pid] = snapshot.windows
                for window in snapshot.windows { self.owners[window.id] = pid }
                self.publish()
            case .failure:
                self.failures[pid] = min(6, (self.failures[pid] ?? 0) + 1)
                self.dirty.insert(pid)
            }
            if self.dirty.remove(pid) != nil { self.schedule(pid) }
        }
    }

    private func publish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled, let self else { return }
            self.publishTask = nil
            self.emitSnapshot()
        }
    }

    /// Different process queues can finish scans that each saw their owner in front.
    /// Only the current foreground process may contribute a focused window.
    static func visibleSnapshot(_ snapshots: [pid_t: [LiveWindow]], frontmost: pid_t?) -> [LiveWindow] {
        snapshots.keys.sorted().flatMap { pid in
            let rows = snapshots[pid] ?? []
            if pid == frontmost { return rows }
            return rows.map { row in
                var window = row
                window.focused = false
                return window
            }
        }
    }

    private func emitSnapshot() {
        onChange?(Self.visibleSnapshot(snapshots, frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier))
    }

    private func worker(_ id: UUID) throws -> ProcessWindows {
        guard trusted else { throw WindowAccessError.permission }
        guard running, !sleeping,
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow",
            let pid = owners[id], let worker = workers[pid],
            let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, !app.isHidden, isAllowed(app),
            app.launchDate == worker.info.launched
        else { throw WindowAccessError.unavailable }
        return worker
    }

    public func read(_ id: UUID) async throws -> LiveWindow {
        let worker = try worker(id)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == worker.info.pid
        return try await worker.perform { try $0.read(id, frontmost: front) }
    }

    public func setFrame(_ frame: CGRect, for id: UUID) async throws {
        guard [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite),
            frame.size.width > 0, frame.size.height > 0
        else { throw WindowAccessError.invalidFrame }
        let worker = try worker(id)
        defer { schedule(worker.info.pid) }
        try await worker.perform { try $0.frame(id, target: frame) }
    }

    public func setMinimized(_ flag: Bool, for id: UUID) async throws {
        let worker = try worker(id)
        defer { schedule(worker.info.pid) }
        try await worker.perform { try $0.minimize(id, flag: flag) }
    }

    public func orderFront(_ id: UUID) async throws {
        let worker = try worker(id)
        defer { schedule(worker.info.pid) }
        try await worker.perform { try $0.orderFront(id) }
    }

    public func focus(_ id: UUID) async throws {
        let worker = try worker(id)
        guard let app = NSRunningApplication(processIdentifier: worker.info.pid) else { throw WindowAccessError.unavailable }
        defer { schedule(worker.info.pid) }
        try await worker.perform { try $0.raise(id) }
        for delay in [0, 50, 100, 150] {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            if app.isActive {
                let confirmed = try await read(id)
                guard confirmed.focused, app.isActive, self.workers[worker.info.pid] === worker else { continue }
                if var rows = snapshots[worker.info.pid], let index = rows.firstIndex(where: { $0.id == id }) {
                    for i in rows.indices { rows[i].focused = false }
                    rows[index] = confirmed
                    snapshots[worker.info.pid] = rows
                    emitSnapshot()
                }
                return
            }
        }
        throw WindowAccessError.verification
    }
}
