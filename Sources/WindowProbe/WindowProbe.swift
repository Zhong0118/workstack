import AppKit
import MacWindows
import WorkbenchCore

@main
struct WindowProbe {
    @MainActor static func main() async {
        let app = NSApplication.shared
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--fixture", let count = arguments.last.flatMap(Int.init), (2...60).contains(count) {
            runFixture(app, count: count)
            return
        }
        let recovery = arguments.count == 2 && arguments.first == "--recovery-smoke"
        guard arguments.isEmpty || arguments == ["--smoke"] || arguments == ["--benchmark"] || recovery else {
            print("Usage: window-probe [--smoke | --benchmark | --recovery-smoke Fixture.app]")
            exit(64)
        }
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let access = MacWindows()
        let smoke = arguments == ["--smoke"]
        print("accessibility=\(access.trusted ? "granted" : "denied") displays=\(MacDisplay.all.count)")
        guard access.trusted else {
            if !arguments.isEmpty { print("fixture=skipped reason=accessibility_permission"); exit(77) }
            print("discovery=skipped reason=accessibility_permission")
            return
        }

        if recovery {
            do {
                try await RecoveryProbe.run(URL(fileURLWithPath: arguments[1]))
                print("recovery=passed fresh_observer=true sibling_isolation=true")
                return
            } catch { print("recovery=failed reason=\(error.localizedDescription)"); exit(1) }
        }
        if arguments == ["--benchmark"] {
            do { try await WindowBenchmark.run(); return } catch {
                print("benchmark=failed reason=\(error.localizedDescription)"); exit(1)
            }
        }
        let fixture = Process()
        if smoke {
            fixture.executableURL = Bundle.main.executableURL
            fixture.arguments = ["--fixture", "2"]
            do { try fixture.run() } catch { print("fixture=failed reason=launch"); exit(1) }
        }
        var latest: [LiveWindow] = []
        var publications = 0
        access.onChange = { windows in
            latest = windows; publications += 1
        }
        access.start()
        let clock = ContinuousClock()
        let start = clock.now
        let end = start.advanced(by: .seconds(smoke ? 12 : 3))
        while clock.now < end {
            if smoke, latest.filter({ $0.identity.pid == fixture.processIdentifier }).count == 2 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let elapsed = start.duration(to: clock.now)
        print(
            "windows=\(latest.count) applications=\(Set(latest.map(\.identity.pid)).count) publications=\(publications) sample_seconds=\(elapsed)"
        )
        var status: Int32 = 0
        if smoke {
            var phase = "initial"
            do {
                let own = latest.filter { $0.identity.pid == fixture.processIdentifier }
                guard own.count == 2, own[0].id != own[1].id, let area = MacDisplay.all.first else {
                    throw WindowAccessError.unavailable
                }
                let target = own[0].id
                let sibling = own[1].id
                let initial = try await access.read(target)
                let other = try await access.read(sibling)
                let frame = CGRect(x: area.frame.minX + 32, y: area.frame.minY + 40, width: 360, height: 250)
                phase = "frame"
                try await access.setFrame(frame, for: target)
                phase = "minimize"
                try await access.setMinimized(true, for: target)
                guard try await access.read(target).minimized,
                    try await access.read(sibling).minimized == other.minimized
                else { throw WindowAccessError.verification }
                do {
                    try await access.focus(target)
                    throw WindowAccessError.verification
                } catch WindowAccessError.unsupported {}
                guard try await access.read(target).minimized else { throw WindowAccessError.verification }
                phase = "unminimize"
                guard try await access.read(target).kind == .normal else { throw WindowAccessError.verification }
                try await access.setMinimized(false, for: target)
                phase = "focusSibling"
                try await access.focus(sibling)
                phase = "focusTarget"
                try await access.focus(target)
                guard try await access.read(target).focused, try await !access.read(sibling).focused,
                    try await access.read(sibling).frame == other.frame
                else { throw WindowAccessError.verification }
                phase = "restore"
                try await access.setFrame(initial.frame, for: target)
                // Simulate a hung application with our own child only. Contain the
                // suspended child to this scope and resume it even if a check fails.
                phase = "timeout"
                let timeoutStart = clock.now
                guard kill(fixture.processIdentifier, SIGSTOP) == 0 else { throw WindowAccessError.unavailable }
                do {
                    defer { _ = kill(fixture.processIdentifier, SIGCONT) }
                    do {
                        _ = try await access.read(target)
                        throw WindowAccessError.verification
                    } catch WindowAccessError.busy {}
                }
                let timeout = timeoutStart.duration(to: clock.now)
                guard timeout < .seconds(3) else { throw WindowAccessError.verification }
                var recovered = false
                for _ in 0..<6 {
                    if let current = try? await access.read(target), current.id == target { recovered = true; break }
                    try await Task.sleep(for: .milliseconds(120))
                }
                guard recovered else { throw WindowAccessError.verification }
                print(
                    "fixture=passed windows=2 operations=frame,minimize,restore,focus,sibling_isolation,timeout_recovery timeout=\(timeout)"
                )
            } catch { print("fixture=failed phase=\(phase) reason=\(error.localizedDescription)"); status = 1 }
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
        }
        access.stop()
        exit(status)
    }

    // A separate, disposable GUI process owns the only windows the smoke test mutates.
    @MainActor private static func runFixture(_ app: NSApplication, count: Int) {
        app.setActivationPolicy(.regular)
        var windows: [NSWindow] = []
        for index in 0..<count {
            let window = NSWindow(
                contentRect: NSRect(x: 100 + (index % 6) * 35, y: 120 + (index % 5) * 25, width: 440, height: 300),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "workstack 测试窗口"
            window.setAccessibilityIdentifier("WorkbenchFixture-\(index)")
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        // Bound fixture lifetime if the invoking process is interrupted.
        let owner = getppid()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if getppid() != owner { exit(0) }
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in exit(0) }
        withExtendedLifetime(windows) { app.run() }
    }
}
