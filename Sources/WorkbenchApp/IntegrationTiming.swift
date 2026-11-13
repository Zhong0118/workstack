import AppKit

@MainActor enum IntegrationTiming {
    struct Usage {
        let cpuSeconds: Double
        let rssMiB: Double
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
            rssMiB = Double(info.resident_size) / 1_048_576
        }
    }

    static func ms(since start: ContinuousClock.Instant) -> Double {
        let time = start.duration(to: .now).components
        return Double(time.seconds) * 1000 + Double(time.attoseconds) / 1e15
    }

    static func idle() async throws {
        try await Task.sleep(for: .seconds(2))
        let start = ContinuousClock.now
        let before = try Usage()
        try await Task.sleep(for: .seconds(15))
        let after = try Usage()
        let seconds = ms(since: start) / 1000
        print(
            String(
                format: "idle seconds=%.2f cpu_pct=%.2f rss_start_mib=%.1f rss_end_mib=%.1f",
                seconds, 100 * (after.cpuSeconds - before.cpuSeconds) / seconds, before.rssMiB, after.rssMiB))
    }

    static func measure(
        _ workload: String, rounds: Int = 20,
        action: (Int) throws -> Void, complete: () -> Bool, confirm: (Int) async throws -> Void
    ) async throws {
        var command = [Double](), confirmed = [Double]()
        let before = try Usage()
        let sampleStart = ContinuousClock.now
        var maxRSS = before.rssMiB
        for index in 0..<rounds {
            let start = ContinuousClock.now
            try action(index)
            while !complete() {
                guard ms(since: start) < 14_000 else { throw POSIXError(.ETIMEDOUT) }
                try await Task.sleep(for: .milliseconds(1))
            }
            command.append(ms(since: start))
            try await confirm(index)
            confirmed.append(ms(since: start))
            maxRSS = max(maxRSS, try Usage().rssMiB)
        }
        let end = try Usage()
        let cpu = 100 * (end.cpuSeconds - before.cpuSeconds) / (ms(since: sampleStart) / 1000)
        for (name, times) in [("command", command), ("confirmed", confirmed)] {
            let sorted = times.sorted()
            print(
                String(
                    format: "gui workload=%@ path=%@ n=%d p50_ms=%.1f p95_ms=%.1f cpu_pct=%.1f rss_mib=%.1f",
                    workload, name, rounds, (sorted[(rounds - 1) / 2] + sorted[rounds / 2]) / 2,
                    sorted[Int(ceil(0.95 * Double(rounds))) - 1], cpu, maxRSS))
        }
    }
}
