import Foundation

/// Copied only into the instrumented simulator package, at the URLSession data callback.
enum RangeInterruption {
    static let marker = URL.documentsDirectory.appendingPathComponent("outage-until")
    private static let state = NSLock()
    nonisolated(unsafe) private static var reportedRestore = false
    nonisolated(unsafe) private static var droppedSources: Set<URL> = []
    static func interrupt(_ task: URLSessionDataTask, incoming: Int) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("qa-direct-fixture") { return false }
        // Pace the cold connection until the first real decoded frames. Otherwise a fast
        // Wi-Fi network could download the entire episode before the requested interruption.
        guard let raw = try? String(contentsOf: marker, encoding: .utf8), let until = Double(raw) else {
            Thread.sleep(forTimeInterval: min(0.3, Double(incoming) / 900_000))
            return false
        }
        guard Date().timeIntervalSince1970 < until else {
            state.lock()
            if !reportedRestore, let url = task.originalRequest?.url, droppedSources.contains(url) {
                reportedRestore = true
                FileHandle.standardOutput.write(Data("FAULT direct transfer restored\n".utf8))
            }
            state.unlock()
            return false
        }
        if task.state == .running {
            if let url = task.originalRequest?.url {
                state.lock(); droppedSources.insert(url); state.unlock()
            }
            task.cancel()
            FileHandle.standardOutput.write(Data("FAULT direct transfer interrupted\n".utf8))
        }
        return true
    }
}
