import Foundation

/// Installed only in the instrumented simulator package. Source URLs never leave the process.
public enum RangeInterruption {
    private static let marker = URL.documentsDirectory.appendingPathComponent("outage-until")
    private static let receipt = URL.documentsDirectory.appendingPathComponent("outage-first-episode-read")
    private static let state = NSLock()
    nonisolated(unsafe) private static var selected: String?
    nonisolated(unsafe) private static var sources: Set<URL> = []
    nonisolated(unsafe) private static var interrupted = false
    nonisolated(unsafe) private static var reportedRestore = false

    public static func select(episodeID: String) {
        state.withLock { selected = episodeID }
    }

    static func associate(_ url: URL, episodeID: String) {
        state.withLock { if episodeID == selected { sources.insert(url) } }
    }

    static func interrupt(_ task: URLSessionDataTask, incoming: Int) -> Bool {
        guard let url = task.originalRequest?.url, state.withLock({ sources.contains(url) }) else { return false }
        guard let raw = try? String(contentsOf: marker, encoding: .utf8), let until = Double(raw) else {
            Thread.sleep(forTimeInterval: min(0.3, Double(incoming) / 900_000))
            return false
        }
        guard Date().timeIntervalSince1970 < until else { return false }
        if task.state == .running {
            state.withLock { interrupted = true }
            task.cancel()
            FileHandle.standardOutput.write(Data("FAULT direct transfer interrupted\n".utf8))
        }
        return true
    }

    static func receivedValidatedRange(_ task: URLSessionTask, startedAt: Double) {
        guard let url = task.originalRequest?.url, let raw = try? String(contentsOf: marker, encoding: .utf8),
              let until = Double(raw) else { return }
        let now = Date().timeIntervalSince1970
        guard now - (ProcessInfo.processInfo.systemUptime - startedAt) >= until else { return }
        state.withLock {
            guard interrupted, !reportedRestore, sources.contains(url) else { return }
            do {
                try String(now).write(to: receipt, atomically: true, encoding: .utf8)
                reportedRestore = true
                FileHandle.standardOutput.write(Data("FAULT direct transfer restored\n".utf8))
            } catch { /* Absence of a valid receipt makes the acceptance test fail. */ }
        }
    }
}
