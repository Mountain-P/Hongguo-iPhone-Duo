import Foundation

/// Content-free timing for one user playback attempt, including automatic recovery.
public struct PlaybackMeasurement: Sendable {
    public enum Context: String, Codable, Sendable { case episode, preview, replay }
    public enum Outcome: String, Codable, Sendable { case completed, cancelled, failed }
    public struct Summary: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let context: Context
        public let outcome: Outcome
        public let recordedAt: Date
        public let durationSeconds: Double
        public let readySeconds: Double?
        public let firstFrameSeconds: Double?
        public let rebufferCount: Int
        public let rebufferSeconds: Double
        public let failureCount: Int
        public let recoveryCount: Int
    }

    private let id: UUID
    private let context: Context
    private let start: Double
    private var last: Double
    private var ready: Double?
    private var firstFrame: Double?
    private var waiting = false
    private var recovering = false
    private var hasPlayed = false
    private var waitingSince: Double?
    private var rebufferSeconds = 0.0
    private var rebufferCount = 0
    private var failureCount = 0
    private var recoveryCount = 0
    private var ended = false

    public init(id: UUID = UUID(), context: Context, startedAt: Double) {
        self.id = id; self.context = context
        start = startedAt.isFinite ? max(0, startedAt) : 0
        last = start
    }

    public mutating func recordReady(at time: Double) {
        guard advance(to: time), ready == nil else { return }
        ready = time - start
    }

    public mutating func recordFirstFrame(at time: Double) {
        guard context != .replay, advance(to: time), firstFrame == nil else { return }
        firstFrame = time - start
        if waiting { waitingSince = time }
    }

    public mutating func recordTransport(waiting nextWaiting: Bool, playing: Bool, at time: Double) {
        guard advance(to: time) else { return }
        // A replacement item is paused while its source/index is being rebuilt.
        // That pause does not mean the user's interrupted playback has resumed.
        if recovering, !playing { return }
        if playing { recovering = false; hasPlayed = true }
        let next = nextWaiting && !playing
        guard waiting != next else { return }
        if let since = waitingSince { rebufferSeconds += time - since }
        waitingSince = nil
        waiting = next
        if next, firstFrame != nil || hasPlayed {
            rebufferCount += 1
            waitingSince = time
        }
    }

    public mutating func recordFailure(recovered: Bool, at time: Double) {
        guard advance(to: time) else { return }
        failureCount += 1
        if recovered {
            recoveryCount += 1
            recovering = true
            if firstFrame != nil || hasPlayed {
                if !waiting { rebufferCount += 1 }
                waiting = true
                if waitingSince == nil { waitingSince = time }
            }
        }
    }

    public mutating func recordPause(at time: Double) {
        guard advance(to: time) else { return }
        if let since = waitingSince { rebufferSeconds += time - since }
        waitingSince = nil; waiting = false; recovering = false
    }

    public mutating func finish(outcome: Outcome, at time: Double, recordedAt: Date = Date()) -> Summary? {
        guard advance(to: time) else { return nil }
        if let since = waitingSince { rebufferSeconds += time - since }
        waitingSince = nil; ended = true
        return Summary(id: id, context: context, outcome: outcome, recordedAt: recordedAt,
            durationSeconds: time - start, readySeconds: ready, firstFrameSeconds: firstFrame,
            rebufferCount: rebufferCount, rebufferSeconds: rebufferSeconds,
            failureCount: failureCount, recoveryCount: recoveryCount)
    }

    private mutating func advance(to time: Double) -> Bool {
        guard !ended, time.isFinite, time >= last else { return false }
        last = time
        return true
    }
}
