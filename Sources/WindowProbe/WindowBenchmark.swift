import AppKit
import Foundation
import MacWindows
import WorkbenchCore

// End-to-end backend benchmark. Every mutation targets a specific child PID/AX UUID.
@MainActor enum WindowBenchmark {
    private static let clock = ContinuousClock()
    private static let rounds = 20

    static func run() async throws {
        for count in [10, 30, 60] { try await scenario(count: count) }
    }

    private static func scenario(count: Int) async throws {
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--fixture", String(count)]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }

        var fixtures: [LiveWindow] = []
        let access = MacWindows()
        access.onChange = { fixtures = $0.filter { $0.identity.pid == child.processIdentifier } }
        access.start()
        defer { access.stop() }
        let deadline = clock.now.advanced(by: .seconds(20))
        while fixtures.count != count && clock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard fixtures.count == count, let area = MacDisplay.all.first else { throw WindowAccessError.unavailable }
        let ids = fixtures.map(\.id)
        let binding = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("journal.json")
        let coordinator = WindowCoordinator(controller: access, journal: RecoveryJournal()) { try LocalFile.write($0, to: journal) }
        let groups = [Array(ids.prefix(4)), Array(ids.dropFirst(4).prefix(4))]
        let cell = CGSize(width: min(area.frame.width / 2 - 12, 420), height: min(area.frame.height / 2 - 12, 300))
        let frames = (0..<4).map {
            CGRect(
                x: area.frame.minX + 6 + CGFloat($0 % 2) * (cell.width + 4),
                y: area.frame.minY + 6 + CGFloat($0 / 2) * (cell.height + 4), width: cell.width, height: cell.height)
        }

        // Warm both workspace layouts; subsequent alternating activations can reuse their geometry.
        for group in groups {
            try await coordinator.perform(zip(group, frames).map { .place($0, $1) }, binding: binding, unique: [])
        }
        for workspace in [false, true] {
            // Alternate strategy order by workload and fixture size.
            let variants = (count == 30) != workspace ? [true, false] : [false, true]
            for cached in variants {
                let sample = try Usage()
                let start = clock.now
                var latencies: [Double] = []
                var peakRSS = sample.rss
                for i in 0..<rounds {
                    let tick = clock.now
                    if !cached {
                        for id in ids { _ = try await access.read(id) }
                    }
                    var commands: [WindowCommand] = []
                    if workspace {
                        for (id, frame) in zip(groups[i % 2], frames) {
                            commands += [.reveal(id), .place(id, frame), .raise(id)]
                        }
                    } else {
                        let target = ids[i % 2]
                        commands = [.reveal(target), .raise(target)]
                    }
                    try await coordinator.perform(commands, binding: binding, unique: [])
                    latencies.append(milliseconds(tick.duration(to: clock.now)))
                    peakRSS = max(peakRSS, try Usage().rss)
                }
                let elapsed = milliseconds(start.duration(to: clock.now))
                let end = try Usage()
                let cpu = 100 * (end.cpuSeconds - sample.cpuSeconds) / (elapsed / 1000)
                latencies.sort()
                let median = (latencies[rounds / 2 - 1] + latencies[rounds / 2]) / 2
                let p95 = latencies[Int(ceil(0.95 * Double(rounds))) - 1]
                let work = workspace ? "workspace" : "window"
                let mode = cached ? "cache" : "reread"
                print(
                    String(
                        format: "n=%d workload=%@ mode=%@ samples=%d p50_ms=%.1f p95_ms=%.1f cpu_pct=%.1f rss_mib=%.1f",
                        count, work, mode, rounds, median, p95, cpu, Double(peakRSS) / 1_048_576))
            }
        }
    }

    private static func milliseconds(_ elapsed: Duration) -> Double {
        Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private struct Usage {
        let cpuSeconds: Double
        let rss: Int32
        init() throws {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
            cpuSeconds =
                Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            var info = mach_task_basic_info()
            var words = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &words)
                }
            }
            guard result == KERN_SUCCESS else { throw POSIXError(.EIO) }
            rss = Int32(clamping: info.resident_size)
        }
    }
}
