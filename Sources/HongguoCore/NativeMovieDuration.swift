// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Duration is a sizing hint only; the MP4 stream validator still owns media validity.
enum NativeMovieDuration {
    static func seconds(in data: Data) -> Double? {
        func integer(_ offset: Int, _ count: Int) -> UInt64? {
            guard offset >= 0, offset <= data.count - count else { return nil }
            return data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func boxes(_ range: Range<Int>, type: String) -> Range<Int>? {
            var cursor = range.lowerBound
            while cursor <= range.upperBound - 8 {
                guard let size = integer(cursor, 4), size >= 8, size <= UInt64(range.upperBound - cursor) else { return nil }
                let end = cursor + Int(size)
                if String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self) == type { return (cursor + 8)..<end }
                cursor = end
            }
            return nil
        }
        guard let moov = boxes(0..<data.count, type: "moov"), let mvhd = boxes(moov, type: "mvhd"),
              let version = integer(mvhd.lowerBound, 1), version <= 1 else { return nil }
        let offset = mvhd.lowerBound + (version == 1 ? 20 : 12), width = version == 1 ? 8 : 4
        guard offset + 4 + width <= mvhd.upperBound, let scale = integer(offset, 4), scale > 0,
              let ticks = integer(offset + 4, width), ticks > 0 else { return nil }
        let seconds = Double(ticks) / Double(scale)
        return seconds.isFinite && (0.1...86_400).contains(seconds) ? seconds : nil
    }
}

public enum PlaybackReadAheadBudget {
    public static func bytes(totalLength: Int, duration: Double?, rate: Float, wallSeconds: Double,
                             minimum: Int, maximum: Int) -> Int {
        guard totalLength > 0 else { return 0 }
        guard let duration, duration.isFinite, duration > 0, rate.isFinite, rate > 0,
              wallSeconds.isFinite, wallSeconds > 0 else { return min(totalLength, minimum) }
        let target = Double(totalLength) * min(1, wallSeconds * Double(rate) / duration)
        return min(totalLength, maximum, max(minimum, Int(min(Double(maximum), target.rounded(.up)))))
    }
}
