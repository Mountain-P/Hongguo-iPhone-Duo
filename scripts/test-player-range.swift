import Foundation

@main
struct RangeChecks {
    static func main() {
        precondition(MediaByteRange.parse("bytes 0-1/100") == MediaByteRange(start: 0, end: 1, total: 100))
        precondition(MediaByteRange.parse("bytes 99-99/100")?.total == 100)
        for value in ["bytes 0-100/100", "bytes -1-2/100", "bytes 5-2/100", "bytes 0-1/*", "bytes */100", "bytes 0-0/0", "items 0-1/100", "bytes 0-1/100 extra", "bytes 0-1/9223372036854775808"] {
            precondition(MediaByteRange.parse(value) == nil, value)
        }
        precondition(MediaByteRange.requestHeader(offset: 100, length: 20, allToEnd: false) == "bytes=100-119")
        precondition(MediaByteRange.requestHeader(offset: 100, length: 20, allToEnd: true) == "bytes=100-")
        precondition(MediaByteRange.requestHeader(offset: .max, length: 2, allToEnd: false) == nil)
        precondition(MediaByteRange.requestHeader(offset: -1, length: 2, allToEnd: false) == nil)
        precondition(MediaByteRange.requestHeader(offset: 0, length: 0, allToEnd: false) == nil)
        precondition(MediaByteRange.sameOrigin(URL(string: "https://EXAMPLE.com/video")!, URL(string: "https://example.com:443/api")!))
        precondition(!MediaByteRange.sameOrigin(URL(string: "https://example.com/video")!, URL(string: "http://example.com/video")!))
        precondition(!MediaByteRange.sameOrigin(URL(string: "https://example.com/video")!, URL(string: "https://evil.example.com/video")!))
        print("Media byte-range checks passed (19 boundary and origin checks).")
    }
}
