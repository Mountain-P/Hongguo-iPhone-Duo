// SPDX-License-Identifier: GPL-3.0-only
// Native BMFF/CENC implementation informed by N3urda/hongguoTV
// eea73e6a45569a2cbbb9440f7cd5290c459b0b70 server/vendor/hongguo.cjs.
// Original provider provenance: Backend/server/vendor/NOTICE.md (GPL-3.0).
// Unlike a byte-pattern replacement, this walks validated sample/box bounds.
import Foundation
import CommonCrypto

public struct NativeMP4ByteRegion: Sendable {
    public let offset: Int
    public let data: Data
    public init(offset: Int, data: Data) { self.offset = offset; self.data = data }
}

public struct NativeMP4StreamRequirements: Error, LocalizedError, Sendable {
    public let ranges: [Range<Int>]
    public init(ranges: [Range<Int>]) { self.ranges = ranges }
    public var errorDescription: String? { "影片索引資料尚未完整。" }
}

/// An immutable index; it retains sample metadata and a key, never the virtual movie buffer.
public struct NativeMP4StreamPlan: Sendable {
    public let totalLength: Int
    fileprivate let samples: [NativeMP4EncryptedSample]
    fileprivate let replacements: [NativeMP4Replacement]
    fileprivate let contentKey: Data?

    public func decrypt(data: Data, offset: Int) throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, offset <= totalLength, data.count <= totalLength - offset else {
            throw NativeMediaError.malformedMP4
        }
        if data.isEmpty { return Data() }
        let end = offset + data.count
        var output = data.startIndex == 0 ? data : Data(Array(data))
        var lower = 0, upper = samples.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].range.upperBound <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        try output.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw NativeMediaError.malformedMP4 }
            var index = lower
            while index < samples.count && samples[index].range.lowerBound < end {
                if index % 64 == 0 { try Task.checkCancellation() }
                let sample = samples[index]
                var cipherOffset = 0
                for range in sample.encryptedRanges {
                    let start = max(offset, range.lowerBound), tail = min(end, range.upperBound)
                    if start < tail {
                        guard let contentKey else { throw NativeMediaError.invalidKey }
                        try Self.decryptRange(base.advanced(by: start - offset), count: tail - start,
                                              key: contentKey, iv: sample.iv,
                                              cipherOffset: cipherOffset + start - range.lowerBound)
                    }
                    cipherOffset += range.count
                }
                index += 1
            }
            for replacement in replacements {
                let typeStart = replacement.box.offset + 4
                let bytes = Array(replacement.type.utf8)
                let start = max(offset, typeStart), tail = min(end, typeStart + bytes.count)
                if start < tail {
                    for global in start..<tail { base.storeBytes(of: bytes[global - typeStart], toByteOffset: global - offset, as: UInt8.self) }
                }
                if replacement.clearBody {
                    let start = max(offset, replacement.box.bodyStart), tail = min(end, replacement.box.end)
                    if start < tail {
                        base.advanced(by: start - offset).initializeMemory(as: UInt8.self, repeating: 0, count: tail - start)
                    }
                }
            }
        }
        try Task.checkCancellation()
        return output
    }

    private static func decryptRange(_ destination: UnsafeMutableRawPointer, count: Int,
                                     key: Data, iv: Data, cipherOffset: Int) throws {
        var counter = [UInt8](iv)
        guard counter.count == 16, key.count == kCCKeySizeAES128 else { throw NativeMediaError.invalidKey }
        var carry = UInt64(cipherOffset / 16)
        for index in stride(from: 15, through: 0, by: -1) {
            let sum = UInt64(counter[index]) + (carry & 0xff)
            counter[index] = UInt8(sum & 0xff)
            carry = (carry >> 8) + (sum >> 8)
        }
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            counter.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard createStatus == kCCSuccess, let cryptor else { throw NativeMediaError.decryptionFailed }
        defer { CCCryptorRelease(cryptor) }
        let leading = cipherOffset % 16
        if leading != 0 {
            var discard = [UInt8](repeating: 0, count: 16)
            var moved = 0
            let status = discard.withUnsafeMutableBytes { bytes in
                CCCryptorUpdate(cryptor, bytes.baseAddress, leading, bytes.baseAddress, leading, &moved)
            }
            guard status == kCCSuccess, moved == leading else { throw NativeMediaError.decryptionFailed }
        }
        var moved = 0
        let status = CCCryptorUpdate(cryptor, UnsafeRawPointer(destination), count, destination, count, &moved)
        guard status == kCCSuccess, moved == count else { throw NativeMediaError.decryptionFailed }
    }
}

public enum NativeMP4 {
    /// Checks a complete, self-contained clear MP4 without modifying any bytes.
    static func validateOfflineClear(data: Data, codec: String? = nil,
                                     maximumBytes: Int64 = Int64(NativeMediaStore.maximumBytes)) throws {
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw NativeMediaError.tooLarge }
        let parser = NativeMP4Parser(data: data, sourceCodec: codec?.lowercased())
        guard try parser.prepare(clearOnly: true).videoEntries > 0 else { throw NativeMediaError.malformedMP4 }
    }

    public static func prepareStream(prefix: Data, totalLength: Int, contentKey: Data?, codec: String,
                                     auxiliary: [NativeMP4ByteRegion] = []) throws -> NativeMP4StreamPlan {
        try Task.checkCancellation()
        let metadataLimit = 8 * 1024 * 1024
        guard totalLength >= 24, totalLength <= NativeMediaStore.maximumBytes,
              prefix.count <= totalLength, prefix.count <= metadataLimit, auxiliary.count <= 4096 else {
            throw NativeMediaError.malformedMP4
        }
        let codec = codec.lowercased()
        guard ["h264", "avc", "avc1", "avc3", "hevc", "h265", "hvc1", "hev1", "bytevc1"].contains(codec) else {
            throw NativeMediaError.unsupportedCodec
        }
        if let contentKey, contentKey.count != kCCKeySizeAES128 { throw NativeMediaError.invalidKey }
        var regions = [NativeMP4ByteRegion(offset: 0, data: prefix)]
        var auxiliaryBytes = 0
        for region in auxiliary {
            try Task.checkCancellation()
            guard region.offset >= 0, region.offset <= totalLength, region.data.count <= totalLength - region.offset,
                  region.data.count <= metadataLimit - auxiliaryBytes else { throw NativeMediaError.malformedMP4 }
            auxiliaryBytes += region.data.count
            for previous in regions {
                let start = max(previous.offset, region.offset)
                let end = min(previous.offset + previous.data.count, region.offset + region.data.count)
                if start < end {
                    let previousStart = previous.data.startIndex + start - previous.offset
                    let currentStart = region.data.startIndex + start - region.offset
                    guard previous.data[previousStart..<(previousStart + end - start)]
                        == region.data[currentStart..<(currentStart + end - start)] else { throw NativeMediaError.malformedMP4 }
                }
            }
            if !region.data.isEmpty { regions.append(region) }
        }
        // This bounded temporary buffer supplies offsets to the existing parser. Coverage
        // checks below ensure no synthetic zero is ever accepted as an IV or box header.
        var virtual = Data(count: totalLength)
        var coverage: [Range<Int>] = []
        for region in regions where !region.data.isEmpty {
            let range = region.offset..<(region.offset + region.data.count)
            virtual.replaceSubrange(range, with: region.data)
            coverage.append(range)
        }
        coverage = nativeMP4MergedRanges(coverage)
        let parser = NativeMP4Parser(data: virtual, sourceCodec: codec, coverage: coverage)
        let preparation = try parser.prepare()
        guard preparation.videoEntries > 0 else { throw NativeMediaError.malformedMP4 }
        if preparation.protectedTracks && preparation.samples.isEmpty { throw NativeMediaError.missingEncryptionMetadata }
        if !preparation.samples.isEmpty && contentKey == nil { throw NativeMediaError.invalidKey }
        try Task.checkCancellation()
        return NativeMP4StreamPlan(totalLength: totalLength,
                                  samples: preparation.samples.sorted { $0.range.lowerBound < $1.range.lowerBound },
                                  replacements: preparation.replacements, contentKey: contentKey)
    }
    /// Converts a complete, non-fragmented CENC MP4 into clear MP4 without changing offsets.
    /// Unsupported encryption layouts are rejected rather than returned as playable media.
    public static func decrypt(data: Data, contentKey: Data?, codec: String) throws -> Data {
        try Task.checkCancellation()
        let data = data.startIndex == 0 ? data : Data(Array(data))
        let codec = codec.lowercased()
        guard ["h264", "avc", "avc1", "avc3", "hevc", "h265", "hvc1", "hev1", "bytevc1"].contains(codec) else {
            throw NativeMediaError.unsupportedCodec
        }
        if let contentKey, contentKey.count != kCCKeySizeAES128 { throw NativeMediaError.invalidKey }
        guard data.count <= NativeMediaStore.maximumBytes else { throw NativeMediaError.tooLarge }
        let parser = NativeMP4Parser(data: data, sourceCodec: codec)
        let preparation = try parser.prepare()
        guard preparation.videoEntries > 0 else { throw NativeMediaError.malformedMP4 }
        if preparation.samples.isEmpty {
            guard !preparation.protectedTracks else { throw NativeMediaError.missingEncryptionMetadata }
            return data
        }
        guard let contentKey else { throw NativeMediaError.invalidKey }
        var output = data
        try output.withUnsafeMutableBytes { raw in
            guard let pointer = raw.baseAddress else { throw NativeMediaError.malformedMP4 }
            for (index, sample) in preparation.samples.enumerated() {
                if index % 64 == 0 { try Task.checkCancellation() }
                var cryptor: CCCryptorRef?
                let createStatus = contentKey.withUnsafeBytes { keyBytes in
                    sample.iv.withUnsafeBytes { ivBytes in
                        CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                            CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress, contentKey.count,
                            nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
                    }
                }
                guard createStatus == kCCSuccess, let cryptor else { throw NativeMediaError.decryptionFailed }
                defer { CCCryptorRelease(cryptor) }
                for range in sample.encryptedRanges where !range.isEmpty {
                    var moved = 0
                    let destination = pointer.advanced(by: range.lowerBound)
                    let status = CCCryptorUpdate(cryptor, UnsafeRawPointer(destination), range.count,
                                                destination, range.count, &moved)
                    guard status == kCCSuccess, moved == range.count else { throw NativeMediaError.decryptionFailed }
                }
                var finalBytes = [UInt8](repeating: 0, count: 16)
                var moved = 0
                let status = finalBytes.withUnsafeMutableBytes { final in
                    CCCryptorFinal(cryptor, final.baseAddress, final.count, &moved)
                }
                guard status == kCCSuccess, moved == 0 else { throw NativeMediaError.decryptionFailed }
            }
            for replacement in preparation.replacements {
                let bytes = Array(replacement.type.utf8)
                guard bytes.count == 4 else { throw NativeMediaError.malformedMP4 }
                bytes.withUnsafeBytes { source in
                    pointer.advanced(by: replacement.box.offset + 4).copyMemory(from: source.baseAddress!, byteCount: 4)
                }
                if replacement.clearBody {
                    pointer.advanced(by: replacement.box.bodyStart).initializeMemory(as: UInt8.self, repeating: 0,
                                                                                   count: replacement.box.end - replacement.box.bodyStart)
                }
            }
        }
        try Task.checkCancellation()
        return output
    }
}

private func nativeMP4MergedRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
    var result: [Range<Int>] = []
    for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if let last = result.last, range.lowerBound <= last.upperBound {
            result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        } else { result.append(range) }
    }
    return result
}

fileprivate struct NativeMP4Box: Sendable {
    let offset: Int
    let end: Int
    let bodyStart: Int
    let type: String
    var body: Range<Int> { bodyStart..<end }
}

private struct NativeMP4Sample {
    let range: Range<Int>
    let chunk: Int
}

fileprivate struct NativeMP4EncryptedSample: Sendable {
    let range: Range<Int>
    let iv: Data
    let encryptedRanges: [Range<Int>]
}

fileprivate struct NativeMP4Replacement: Sendable {
    let box: NativeMP4Box
    let type: String
    let clearBody: Bool
}

private struct NativeMP4Preparation {
    var samples: [NativeMP4EncryptedSample] = []
    var replacements: [NativeMP4Replacement] = []
    var videoEntries = 0
    var protectedTracks = false
}

private struct NativeMP4EncryptionInfo {
    let ivSize: Int
    let originalCodec: String
}

private final class NativeMP4Parser {
    private let data: Data
    private let sourceCodec: String?
    private let coverage: [Range<Int>]?
    private let maximumSamples = 250_000
    private var boxCount = 0
    private var auxiliaryBytes = 0

    init(data: Data, sourceCodec: String?, coverage: [Range<Int>]? = nil) {
        self.data = data; self.sourceCodec = sourceCodec; self.coverage = coverage
    }

    func prepare(clearOnly: Bool = false) throws -> NativeMP4Preparation {
        guard data.count >= 24 else { throw NativeMediaError.malformedMP4 }
        let top = try boxes(in: 0..<data.count)
        guard top.filter({ $0.type == "ftyp" }).count == 1,
              let ftyp = top.first(where: { $0.type == "ftyp" }), ftyp.body.count >= 8,
              top.filter({ $0.type == "moov" }).count == 1,
              let moov = top.first(where: { $0.type == "moov" }) else { throw NativeMediaError.malformedMP4 }
        if coverage != nil {
            guard moov.end <= 8 * 1024 * 1024 else { throw NativeMediaError.malformedMP4 }
            try require(moov.bodyStart, moov.body.count, within: moov.body)
        }
        guard !top.contains(where: { $0.type == "moof" }) else { throw NativeMediaError.unsupportedEncryption }
        let media = top.filter { $0.type == "mdat" }.map(\.body)
        guard media.contains(where: { !$0.isEmpty }) else { throw NativeMediaError.malformedMP4 }
        let movieChildren = try boxes(in: moov.body)
        guard !movieChildren.contains(where: { $0.type == "mvex" }) else { throw NativeMediaError.unsupportedEncryption }
        if clearOnly {
            guard top.first?.type == "ftyp", media.count == 1 else { throw NativeMediaError.malformedMP4 }
            guard !top.contains(where: { $0.type == "pssh" }),
                  !movieChildren.contains(where: { $0.type == "pssh" }) else { throw NativeMediaError.unsupportedEncryption }
        }
        var result = NativeMP4Preparation()
        for track in movieChildren where track.type == "trak" {
            try Task.checkCancellation()
            let mdia = try requiredChild("mdia", of: track)
            let minf = try requiredChild("minf", of: mdia)
            let stbl = try requiredChild("stbl", of: minf)
            let table = try boxes(in: stbl.body)
            guard let stsd = try unique("stsd", in: table) else { throw NativeMediaError.malformedMP4 }
            try require(stsd.bodyStart, 8, within: stsd.body)
            guard try u8(stsd.bodyStart) == 0 else { throw NativeMediaError.unsupportedEncryption }
            let descriptions = try boxes(in: (stsd.bodyStart + 8)..<stsd.end)
            guard descriptions.count == (try count32(stsd.bodyStart + 4, limit: 32)) else { throw NativeMediaError.malformedMP4 }
            if clearOnly {
                result.videoEntries += try validateClearTrack(minf: minf, table: table, descriptions: descriptions, media: media)
                continue
            }
            var encryptedDescriptions: [NativeMP4EncryptionInfo] = []
            var hasClearDescription = false
            for entry in descriptions {
                switch entry.type {
                case "avc1", "avc3", "hvc1", "hev1":
                    try validateVideoCodec(entry.type)
                    result.videoEntries += 1
                    hasClearDescription = true
                case "encv", "enca":
                    let info = try encryptionInfo(entry)
                    encryptedDescriptions.append(info)
                    if entry.type == "encv" {
                        try validateVideoCodec(info.originalCodec)
                        result.videoEntries += 1
                    } else {
                        guard info.originalCodec == "mp4a" else { throw NativeMediaError.unsupportedCodec }
                    }
                    result.replacements.append(.init(box: entry, type: info.originalCodec, clearBody: false))
                    let children = try sampleEntryChildren(entry)
                    guard let sinf = try unique("sinf", in: children) else { throw NativeMediaError.missingEncryptionMetadata }
                    result.replacements.append(.init(box: sinf, type: "free", clearBody: true))
                case "enct", "encs":
                    throw NativeMediaError.unsupportedEncryption
                default:
                    hasClearDescription = true
                }
            }
            guard !encryptedDescriptions.isEmpty else {
                if table.contains(where: { $0.type == "senc" }) { throw NativeMediaError.missingEncryptionMetadata }
                continue
            }
            result.protectedTracks = true
            guard !hasClearDescription, let encryption = encryptedDescriptions.first,
                  encryptedDescriptions.allSatisfy({ $0.ivSize == encryption.ivSize }) else {
                throw NativeMediaError.unsupportedEncryption
            }
            for group in table where group.type == "sgpd" || group.type == "sbgp" {
                try require(group.bodyStart, 8, within: group.body)
                if try fourcc(group.bodyStart + 4) == "seig" { throw NativeMediaError.unsupportedEncryption }
            }
            let samples = try sampleIndex(table: table, descriptionCount: descriptions.count, media: media)
            guard !samples.isEmpty, result.samples.count + samples.count <= maximumSamples else { throw NativeMediaError.malformedMP4 }
            let saiz = try unique("saiz", in: table)
            let saio = try unique("saio", in: table)
            let auxiliarySizes = try saiz.map { try auxSizes($0, count: samples.count) }
            if let senc = try unique("senc", in: table) {
                result.samples += try sencSamples(senc, samples: samples, ivSize: encryption.ivSize, auxiliarySizes: auxiliarySizes)
            } else {
                guard let auxiliarySizes, let saio else { throw NativeMediaError.missingEncryptionMetadata }
                let offsets = try auxOffsets(saio)
                result.samples += try externalAuxSamples(samples: samples, sizes: auxiliarySizes,
                                                         offsets: offsets, ivSize: encryption.ivSize)
            }
            for box in table where ["senc", "saiz", "saio"].contains(box.type) {
                result.replacements.append(.init(box: box, type: "free", clearBody: true))
            }
        }
        let sorted = result.samples.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var end = 0
        for sample in sorted {
            guard sample.range.lowerBound >= end else { throw NativeMediaError.malformedMP4 }
            end = sample.range.upperBound
        }
        return result
    }

    private func validateClearTrack(minf: NativeMP4Box, table: [NativeMP4Box], descriptions: [NativeMP4Box],
                                    media: [Range<Int>]) throws -> Int {
        guard !descriptions.isEmpty else { throw NativeMediaError.malformedMP4 }
        guard !table.contains(where: { ["senc", "saiz", "saio", "pssh"].contains($0.type) }) else {
            throw NativeMediaError.unsupportedEncryption
        }
        for group in table where group.type == "sgpd" || group.type == "sbgp" {
            try require(group.bodyStart, 8, within: group.body)
            if try fourcc(group.bodyStart + 4) == "seig" { throw NativeMediaError.unsupportedEncryption }
        }
        let dinf = try requiredChild("dinf", of: minf)
        let dref = try requiredChild("dref", of: dinf)
        try require(dref.bodyStart, 8, within: dref.body)
        let references = try boxes(in: (dref.bodyStart + 8)..<dref.end)
        guard try u32(dref.bodyStart) == 0,
              references.count == (try count32(dref.bodyStart + 4, limit: 32)), !references.isEmpty else {
            throw NativeMediaError.malformedMP4
        }
        // An offline file must never require AVFoundation to open an external data reference.
        for reference in references {
            guard reference.type == "url ", reference.body.count == 4,
                  try u32(reference.bodyStart) == 1 else { throw NativeMediaError.malformedMP4 }
        }
        var videos = 0
        for entry in descriptions {
            if ["encv", "enca", "enct", "encs", "drms", "drmi"].contains(entry.type) {
                throw NativeMediaError.unsupportedEncryption
            }
            if ["avc1", "avc3", "hvc1", "hev1"].contains(entry.type) {
                try validateVideoCodec(entry.type)
                videos += 1
            } else if entry.type != "mp4a" { throw NativeMediaError.unsupportedCodec }
            try require(entry.bodyStart, 8, within: entry.body)
            guard try (1...references.count).contains(Int(u16(entry.bodyStart + 6))) else {
                throw NativeMediaError.malformedMP4
            }
            guard try !sampleEntryChildren(entry).contains(where: { ["sinf", "schm", "schi", "tenc", "pssh"].contains($0.type) }) else {
                throw NativeMediaError.unsupportedEncryption
            }
        }
        let samples: [NativeMP4Sample]
        do { samples = try sampleIndex(table: table, descriptionCount: descriptions.count, media: media) }
        catch NativeMediaError.missingEncryptionMetadata { throw NativeMediaError.malformedMP4 }
        guard samples.contains(where: { !$0.range.isEmpty }), let stts = try unique("stts", in: table) else {
            throw NativeMediaError.malformedMP4
        }
        try require(stts.bodyStart, 8, within: stts.body)
        let timingCount = try count32(stts.bodyStart + 4, limit: maximumSamples)
        try require(stts.bodyStart + 8, timingCount * 8, within: stts.body)
        guard try u32(stts.bodyStart) == 0 else { throw NativeMediaError.malformedMP4 }
        var timedSamples = 0
        var hasDuration = false
        for index in 0..<timingCount {
            if index % 512 == 0 { try Task.checkCancellation() }
            let offset = stts.bodyStart + 8 + index * 8
            let count = Int(try u32(offset))
            guard count > 0, count <= samples.count - timedSamples else { throw NativeMediaError.malformedMP4 }
            timedSamples += count
            if try u32(offset + 4) > 0 { hasDuration = true }
        }
        guard timedSamples == samples.count, hasDuration else { throw NativeMediaError.malformedMP4 }
        return videos
    }

    private func sampleEntryChildren(_ entry: NativeMP4Box) throws -> [NativeMP4Box] {
        let headerSize: Int
        if ["encv", "avc1", "avc3", "hvc1", "hev1"].contains(entry.type) { headerSize = 78 }
        else {
            try require(entry.bodyStart, 28, within: entry.body)
            switch try u16(entry.bodyStart + 8) {
            case 0: headerSize = 28
            case 1: headerSize = 44
            case 2: headerSize = 64
            default: throw NativeMediaError.unsupportedEncryption
            }
        }
        try require(entry.bodyStart, headerSize, within: entry.body)
        return try boxes(in: (entry.bodyStart + headerSize)..<entry.end)
    }

    private func encryptionInfo(_ entry: NativeMP4Box) throws -> NativeMP4EncryptionInfo {
        let children = try sampleEntryChildren(entry)
        guard let sinf = try unique("sinf", in: children) else { throw NativeMediaError.missingEncryptionMetadata }
        let info = try boxes(in: sinf.body)
        guard let frma = try unique("frma", in: info), frma.body.count == 4,
              let schm = try unique("schm", in: info), schm.body.count >= 12,
              let schi = try unique("schi", in: info),
              let tenc = try unique("tenc", in: boxes(in: schi.body)) else { throw NativeMediaError.missingEncryptionMetadata }
        guard try fourcc(schm.bodyStart + 4) == "cenc" else { throw NativeMediaError.unsupportedEncryption }
        try require(tenc.bodyStart, 24, within: tenc.body)
        let version = try u8(tenc.bodyStart)
        let pattern = try u8(tenc.bodyStart + 5)
        guard version <= 1, try u8(tenc.bodyStart + 6) == 1,
              version == 0 || pattern == 0 else { throw NativeMediaError.unsupportedEncryption }
        let iv = Int(try u8(tenc.bodyStart + 7))
        guard iv == 8 || iv == 16 else { throw NativeMediaError.unsupportedEncryption }
        return .init(ivSize: iv, originalCodec: try fourcc(frma.bodyStart))
    }

    private func validateVideoCodec(_ code: String) throws {
        let avc = ["avc1", "avc3"].contains(code)
        let hevc = ["hvc1", "hev1"].contains(code)
        guard avc || hevc else { throw NativeMediaError.unsupportedCodec }
        guard let sourceCodec else { return }
        let sourceAVC = ["h264", "avc", "avc1", "avc3"].contains(sourceCodec)
        guard (avc && sourceAVC) || (hevc && !sourceAVC) else { throw NativeMediaError.unsupportedCodec }
    }

    private func sampleIndex(table: [NativeMP4Box], descriptionCount: Int,
                             media: [Range<Int>]) throws -> [NativeMP4Sample] {
        guard let stsz = try unique("stsz", in: table), let stsc = try unique("stsc", in: table) else {
            throw NativeMediaError.missingEncryptionMetadata
        }
        let stco = try unique("stco", in: table)
        let co64 = try unique("co64", in: table)
        guard (stco == nil) != (co64 == nil), let chunksBox = stco ?? co64 else { throw NativeMediaError.malformedMP4 }
        try require(stsz.bodyStart, 12, within: stsz.body)
        try require(stsc.bodyStart, 8, within: stsc.body)
        try require(chunksBox.bodyStart, 8, within: chunksBox.body)
        guard try u32(stsz.bodyStart) == 0, try u32(stsc.bodyStart) == 0,
              try u32(chunksBox.bodyStart) == 0 else { throw NativeMediaError.unsupportedEncryption }
        let count = try count32(stsz.bodyStart + 8, limit: maximumSamples)
        let fixedSize = Int(try u32(stsz.bodyStart + 4))
        if fixedSize == 0 { try require(stsz.bodyStart + 12, count * 4, within: stsz.body) }
        let sizes = try (0..<count).map { fixedSize == 0 ? Int(try u32(stsz.bodyStart + 12 + $0 * 4)) : fixedSize }
        let chunks = try count32(chunksBox.bodyStart + 4, limit: maximumSamples)
        let width = chunksBox.type == "co64" ? 8 : 4
        try require(chunksBox.bodyStart + 8, chunks * width, within: chunksBox.body)
        let offsets = try (0..<chunks).map { index -> Int in
            let location = chunksBox.bodyStart + 8 + index * width
            return width == 8 ? try offset64(location) : Int(try u32(location))
        }
        let entryCount = try count32(stsc.bodyStart + 4, limit: maximumSamples)
        try require(stsc.bodyStart + 8, entryCount * 12, within: stsc.body)
        var entries: [(first: Int, count: Int)] = []
        for index in 0..<entryCount {
            let location = stsc.bodyStart + 8 + index * 12
            let first = Int(try u32(location)), perChunk = Int(try u32(location + 4))
            let description = Int(try u32(location + 8))
            guard first > (entries.last?.first ?? 0), first <= chunks, perChunk > 0,
                  description >= 1, description <= descriptionCount else { throw NativeMediaError.malformedMP4 }
            entries.append((first, perChunk))
        }
        guard entries.first?.first == 1 else { throw NativeMediaError.malformedMP4 }
        var output: [NativeMP4Sample] = []
        output.reserveCapacity(count)
        var entryIndex = 0, sampleIndex = 0
        for (chunk, start) in offsets.enumerated() {
            if chunk % 512 == 0 { try Task.checkCancellation() }
            while entryIndex + 1 < entries.count && entries[entryIndex + 1].first <= chunk + 1 { entryIndex += 1 }
            let inChunk = entries[entryIndex].count
            guard inChunk <= count - sampleIndex else { throw NativeMediaError.malformedMP4 }
            var location = start
            for _ in 0..<inChunk {
                let end = try add(location, sizes[sampleIndex])
                guard media.contains(where: { location >= $0.lowerBound && end <= $0.upperBound }) else { throw NativeMediaError.malformedMP4 }
                output.append(.init(range: location..<end, chunk: chunk))
                location = end; sampleIndex += 1
            }
        }
        guard sampleIndex == count else { throw NativeMediaError.malformedMP4 }
        return output
    }

    private func auxSizes(_ box: NativeMP4Box, count: Int) throws -> [Int] {
        try require(box.bodyStart, 9, within: box.body)
        let flags = try u32(box.bodyStart) & 0x00ff_ffff
        guard try u8(box.bodyStart) == 0, flags & ~1 == 0 else { throw NativeMediaError.unsupportedEncryption }
        let skip = flags & 1 != 0 ? 8 : 0
        try require(box.bodyStart + 4, skip + 5, within: box.body)
        if skip != 0, try fourcc(box.bodyStart + 4) != "cenc" { throw NativeMediaError.unsupportedEncryption }
        let position = box.bodyStart + 4 + skip
        let fixed = Int(try u8(position))
        guard try count32(position + 1, limit: maximumSamples) == count else { throw NativeMediaError.malformedMP4 }
        if fixed != 0 { return Array(repeating: fixed, count: count) }
        try require(position + 5, count, within: box.body)
        return try (0..<count).map { Int(try u8(position + 5 + $0)) }
    }

    private func auxOffsets(_ box: NativeMP4Box) throws -> [Int] {
        try require(box.bodyStart, 8, within: box.body)
        let version = try u8(box.bodyStart), flags = try u32(box.bodyStart) & 0x00ff_ffff
        guard version <= 1, flags & ~1 == 0 else { throw NativeMediaError.unsupportedEncryption }
        let skip = flags & 1 != 0 ? 8 : 0
        try require(box.bodyStart + 4, skip + 4, within: box.body)
        if skip != 0, try fourcc(box.bodyStart + 4) != "cenc" { throw NativeMediaError.unsupportedEncryption }
        let at = box.bodyStart + 4 + skip
        let count = try count32(at, limit: maximumSamples), width = version == 1 ? 8 : 4
        guard count > 0 else { throw NativeMediaError.malformedMP4 }
        try require(at + 4, count * width, within: box.body)
        return try (0..<count).map { width == 8 ? try offset64(at + 4 + $0 * width) : Int(try u32(at + 4 + $0 * width)) }
    }

    private func sencSamples(_ box: NativeMP4Box, samples: [NativeMP4Sample], ivSize: Int,
                             auxiliarySizes: [Int]?) throws -> [NativeMP4EncryptedSample] {
        try require(box.bodyStart, 8, within: box.body)
        let flags = try u32(box.bodyStart) & 0x00ff_ffff
        guard try u8(box.bodyStart) == 0, flags & ~3 == 0 else { throw NativeMediaError.unsupportedEncryption }
        var cursor = box.bodyStart + 4, size = ivSize
        if flags & 1 != 0 {
            try require(cursor, 20, within: box.body)
            guard try u24(cursor) == 1 else { throw NativeMediaError.unsupportedEncryption }
            size = Int(try u8(cursor + 3))
            guard size == 8 || size == 16 else { throw NativeMediaError.unsupportedEncryption }
            cursor += 20
        }
        guard try count32(cursor, limit: maximumSamples) == samples.count else { throw NativeMediaError.malformedMP4 }
        cursor += 4
        var output: [NativeMP4EncryptedSample] = []
        output.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            let start = cursor
            let item = try encryptionRecord(sample: sample, cursor: &cursor, end: box.end,
                                            ivSize: size, subsamples: flags & 2 != 0)
            if let auxiliarySizes, auxiliarySizes[index] != cursor - start { throw NativeMediaError.malformedMP4 }
            output.append(item)
        }
        guard cursor == box.end || data[cursor..<box.end].allSatisfy({ $0 == 0 }) else { throw NativeMediaError.malformedMP4 }
        return output
    }

    private func externalAuxSamples(samples: [NativeMP4Sample], sizes: [Int], offsets: [Int],
                                    ivSize: Int) throws -> [NativeMP4EncryptedSample] {
        let chunks = (samples.last?.chunk ?? -1) + 1
        guard offsets.count == 1 || offsets.count == chunks else { throw NativeMediaError.unsupportedEncryption }
        if coverage != nil {
            let total = sizes.reduce(0, +)
            guard total <= 8 * 1024 * 1024 - auxiliaryBytes else { throw NativeMediaError.malformedMP4 }
            auxiliaryBytes += total
            var cursor = offsets[0], previousChunk = -1
            var missing: [Range<Int>] = []
            for (index, sample) in samples.enumerated() {
                if index % 512 == 0 { try Task.checkCancellation() }
                if offsets.count != 1 && previousChunk != sample.chunk { cursor = offsets[sample.chunk] }
                let size = sizes[index], end = try add(cursor, size)
                guard size >= ivSize, end <= data.count else { throw NativeMediaError.malformedMP4 }
                missing += missingRanges(in: cursor..<end)
                cursor = end
                previousChunk = sample.chunk
            }
            if !missing.isEmpty { throw NativeMP4StreamRequirements(ranges: nativeMP4MergedRanges(missing)) }
        }
        var cursor = offsets[0], previousChunk = -1
        var output: [NativeMP4EncryptedSample] = []
        output.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            if offsets.count != 1 && previousChunk != sample.chunk { cursor = offsets[sample.chunk] }
            let size = sizes[index], end = try add(cursor, size)
            guard size >= ivSize else { throw NativeMediaError.malformedMP4 }
            try require(cursor, size, within: 0..<data.count)
            let value = try encryptionRecord(sample: sample, cursor: &cursor, end: end, ivSize: ivSize,
                                             subsamples: size > ivSize)
            guard cursor == end else { throw NativeMediaError.malformedMP4 }
            output.append(value)
            previousChunk = sample.chunk
        }
        return output
    }

    private func encryptionRecord(sample: NativeMP4Sample, cursor: inout Int, end: Int,
                                  ivSize: Int, subsamples: Bool) throws -> NativeMP4EncryptedSample {
        try require(cursor, ivSize, within: 0..<end)
        var iv = Data(data[cursor..<(cursor + ivSize)])
        if ivSize == 8 { iv.append(Data(repeating: 0, count: 8)) }
        cursor += ivSize
        var encrypted: [Range<Int>] = []
        if subsamples {
            try require(cursor, 2, within: 0..<end)
            let count = Int(try u16(cursor)); cursor += 2
            guard count <= 4096 else { throw NativeMediaError.malformedMP4 }
            try require(cursor, count * 6, within: 0..<end)
            if count == 0 { encrypted = [sample.range] }
            else {
                var location = sample.range.lowerBound
                for _ in 0..<count {
                    location = try add(location, Int(try u16(cursor)))
                    let tail = try add(location, Int(try u32(cursor + 2)))
                    guard tail <= sample.range.upperBound else { throw NativeMediaError.malformedMP4 }
                    encrypted.append(location..<tail)
                    location = tail; cursor += 6
                }
                guard location == sample.range.upperBound else { throw NativeMediaError.malformedMP4 }
            }
        } else { encrypted = [sample.range] }
        return .init(range: sample.range, iv: iv, encryptedRanges: encrypted)
    }

    private func requiredChild(_ type: String, of parent: NativeMP4Box) throws -> NativeMP4Box {
        guard let result = try unique(type, in: boxes(in: parent.body)) else { throw NativeMediaError.malformedMP4 }
        return result
    }

    private func unique(_ type: String, in children: [NativeMP4Box]) throws -> NativeMP4Box? {
        let found = children.filter { $0.type == type }
        guard found.count <= 1 else { throw NativeMediaError.malformedMP4 }
        return found.first
    }

    private func boxes(in range: Range<Int>) throws -> [NativeMP4Box] {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { throw NativeMediaError.malformedMP4 }
        var cursor = range.lowerBound, output: [NativeMP4Box] = []
        while cursor < range.upperBound {
            if boxCount % 512 == 0 { try Task.checkCancellation() }
            try require(cursor, 8, within: range)
            var size = Int(try u32(cursor)), header = 8
            if size == 1 {
                try require(cursor, 16, within: range)
                size = try offset64(cursor + 8); header = 16
            } else if size == 0 { size = range.upperBound - cursor }
            let end = try add(cursor, size)
            guard size >= header, end <= range.upperBound else { throw NativeMediaError.malformedMP4 }
            boxCount += 1
            guard boxCount <= 50_000 else { throw NativeMediaError.malformedMP4 }
            output.append(.init(offset: cursor, end: end, bodyStart: cursor + header, type: try fourcc(cursor + 4)))
            cursor = end
        }
        return output
    }

    private func require(_ offset: Int, _ size: Int, within range: Range<Int>) throws {
        guard offset >= range.lowerBound, size >= 0, offset <= range.upperBound,
              size <= range.upperBound - offset, range.upperBound <= data.count else { throw NativeMediaError.malformedMP4 }
        let missing = missingRanges(in: offset..<(offset + size))
        if !missing.isEmpty { throw NativeMP4StreamRequirements(ranges: missing) }
    }

    private func missingRanges(in range: Range<Int>) -> [Range<Int>] {
        guard let coverage, !range.isEmpty else { return [] }
        var cursor = range.lowerBound, missing: [Range<Int>] = []
        for available in coverage {
            if available.upperBound <= cursor { continue }
            if available.lowerBound >= range.upperBound { break }
            if available.lowerBound > cursor { missing.append(cursor..<min(available.lowerBound, range.upperBound)) }
            cursor = max(cursor, available.upperBound)
            if cursor >= range.upperBound { break }
        }
        if cursor < range.upperBound { missing.append(cursor..<range.upperBound) }
        return missing
    }

    private func add(_ first: Int, _ second: Int) throws -> Int {
        let (result, overflow) = first.addingReportingOverflow(second)
        guard !overflow, first >= 0, second >= 0 else { throw NativeMediaError.malformedMP4 }
        return result
    }

    private func u8(_ offset: Int) throws -> UInt8 {
        try require(offset, 1, within: 0..<data.count); return data[offset]
    }
    private func u16(_ offset: Int) throws -> UInt16 {
        try require(offset, 2, within: 0..<data.count)
        return data.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }
    private func u24(_ offset: Int) throws -> UInt32 {
        (UInt32(try u8(offset)) << 16) | (UInt32(try u8(offset + 1)) << 8) | UInt32(try u8(offset + 2))
    }
    private func u32(_ offset: Int) throws -> UInt32 {
        try require(offset, 4, within: 0..<data.count)
        return data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    private func offset64(_ offset: Int) throws -> Int {
        try require(offset, 8, within: 0..<data.count)
        let value = data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        guard value <= UInt64(Int.max) else { throw NativeMediaError.malformedMP4 }
        return Int(value)
    }
    private func count32(_ offset: Int, limit: Int) throws -> Int {
        let value = Int(try u32(offset))
        guard value <= limit else { throw NativeMediaError.malformedMP4 }
        return value
    }
    private func fourcc(_ offset: Int) throws -> String {
        try require(offset, 4, within: 0..<data.count)
        return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }
}
