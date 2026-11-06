import Foundation
import Testing
@testable import HongguoCore

struct NativeMP4StreamingTests {
    private let key = streamHex("2b7e151628aed2a6abf7158809cf4f3c")
    private let iv = streamHex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
    private let plain = streamHex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
    private let cipher = streamHex("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff5ae4df3edbd5d35e5b4f09020db03eab1e031dda2fbe03d1792170a0f3009cee")

    @Test
    func arbitraryChunksMatchWholeFileForClearAVCAndEncryptedAVCAndHEVC() throws {
        for (fixture, codec, contentKey) in [
            (streamFixture(payload: plain), "h264", nil),
            (streamFixture(payload: cipher, iv: iv), "h264", Optional(key)),
            (streamFixture(payload: cipher, iv: iv, originalCodec: "hvc1"), "hevc", Optional(key))
        ] {
            let plan = try NativeMP4.prepareStream(prefix: fixture.data.prefix(fixture.prefixCount), totalLength: fixture.data.count,
                                                 contentKey: contentKey, codec: codec)
            #expect(plan.totalLength == fixture.data.count)
            let complete = try NativeMP4.decrypt(data: fixture.data, contentKey: contentKey, codec: codec)
            for size in [1, 7, 15, 16, 17, 63, 512] {
                var joined = Data()
                for offset in stride(from: 0, to: fixture.data.count, by: size) {
                    let tail = min(offset + size, fixture.data.count)
                    // Data.SubSequence preserves nonzero startIndex; the public API accepts it.
                    let bytes = try plan.decrypt(data: fixture.data[offset..<tail], offset: offset)
                    #expect(bytes.count == tail - offset)
                    joined += bytes
                }
                #expect(joined == complete)
            }
            for media in fixture.media { #expect(complete[media] == plain) }
        }
    }

    @Test
    func randomAccessRestartsEachSampleCounterAndHandlesUnalignedAESBlocks() throws {
        let fixture = streamFixture(payload: cipher, iv: iv, samples: 3)
        let plan = try NativeMP4.prepareStream(prefix: fixture.data.prefix(fixture.prefixCount), totalLength: fixture.data.count, contentKey: key, codec: "h264")
        let complete = try NativeMP4.decrypt(data: fixture.data, contentKey: key, codec: "h264")
        for sample in fixture.media.reversed() {
            for relative in [63, 33, 31, 17, 16, 15, 7, 1, 0] {
                let start = sample.lowerBound + relative
                let end = min(start + 35, fixture.data.count)
                #expect(try plan.decrypt(data: fixture.data[start..<end], offset: start) == complete[start..<end])
            }
        }
        #expect(try plan.decrypt(data: Data(), offset: fixture.data.count).isEmpty)
        #expect(throws: NativeMediaError.malformedMP4) { try plan.decrypt(data: Data([1]), offset: -1) }
        #expect(throws: NativeMediaError.malformedMP4) { try plan.decrypt(data: Data([1]), offset: fixture.data.count) }
        #expect(throws: NativeMediaError.malformedMP4) { try plan.decrypt(data: Data(), offset: Int.max) }
    }

    @Test
    func eightByteIVAndSubsampleClearGapsUseOnlyEncryptedBytePositions() throws {
        let eightCipher = streamHex("19ce20015553385e50b3eb4c2523e4390a1c99741d0d6cb96780e3fcf631a88debc1aa3eeb35fe73fe5670c274c2524f383a5868d9639126bcb6ec4fee3b936b")
        let eight = streamFixture(payload: eightCipher, iv: streamHex("0001020304050607"))
        let partialCipher = streamHex("a2c58c27a71319d79fb77801c7f0d489544e0e115741")
        let payload = Data("CLR".utf8) + partialCipher.prefix(5) + Data("PASS".utf8) + partialCipher.dropFirst(5)
        let subsamples = streamFixture(payload: payload, iv: iv, subsamples: [(3, 5), (4, 17)])
        for fixture in [eight, subsamples] {
            let plan = try NativeMP4.prepareStream(prefix: fixture.data.prefix(fixture.prefixCount), totalLength: fixture.data.count, contentKey: key, codec: "h264")
            let complete = try NativeMP4.decrypt(data: fixture.data, contentKey: key, codec: "h264")
            for media in fixture.media {
                for relative in 0..<media.count {
                    let start = media.lowerBound + relative, end = min(start + 19, fixture.data.count)
                    #expect(try plan.decrypt(data: fixture.data[start..<end], offset: start) == complete[start..<end])
                }
            }
        }
        let clear = try NativeMP4.decrypt(data: subsamples.data, contentKey: key, codec: "h264")
        #expect(clear[subsamples.media[0]] == Data("CLRNIST?PASSsegment-number-02".utf8))
    }

    @Test
    func missingExternalIVsAreRequestedAndPartialCoverageCannotBecomeZeroIVs() throws {
        let fixture = streamFixture(payload: cipher, iv: iv, samples: 3, external: true)
        let auxiliary = try #require(fixture.auxiliary)
        var requirements: NativeMP4StreamRequirements?
        do {
            _ = try NativeMP4.prepareStream(prefix: fixture.data.prefix(fixture.prefixCount), totalLength: fixture.data.count, contentKey: key, codec: "h264")
            Issue.record("Missing auxiliary bytes must be requested before parsing IVs")
        } catch let missing as NativeMP4StreamRequirements { requirements = missing }
        #expect(requirements?.ranges == [auxiliary])
        let firstFive = NativeMP4ByteRegion(offset: auxiliary.lowerBound, data: fixture.data[auxiliary.lowerBound..<(auxiliary.lowerBound + 5)])
        do {
            _ = try NativeMP4.prepareStream(prefix: fixture.data.prefix(fixture.prefixCount), totalLength: fixture.data.count, contentKey: key, codec: "h264", auxiliary: [firstFive])
            Issue.record("Partial IV coverage must not be accepted")
        } catch let missing as NativeMP4StreamRequirements {
            #expect(missing.ranges == [(auxiliary.lowerBound + 5)..<auxiliary.upperBound])
        }
        let regions = try #require(requirements).ranges.map { NativeMP4ByteRegion(offset: $0.lowerBound, data: fixture.data[$0]) }
        let plan = try NativeMP4.prepareStream(prefix: fixture.data.prefix(fixture.prefixCount), totalLength: fixture.data.count, contentKey: key, codec: "h264", auxiliary: regions)
        let complete = try NativeMP4.decrypt(data: fixture.data, contentKey: key, codec: "h264")
        for offset in stride(from: fixture.data.count - 1, through: 0, by: -13) {
            let end = min(offset + 31, fixture.data.count)
            #expect(try plan.decrypt(data: fixture.data[offset..<end], offset: offset) == complete[offset..<end])
        }
    }

    @Test
    func prefixAndAuxiliaryRegionsAreBoundedAndConflictingOverlapIsRejected() throws {
        let fixture = streamFixture(payload: cipher, iv: iv, external: true)
        let prefix = Data(fixture.data.prefix(fixture.prefixCount))
        for region in [NativeMP4ByteRegion(offset: -1, data: Data([0])), NativeMP4ByteRegion(offset: Int.max, data: Data([0])),
                       NativeMP4ByteRegion(offset: fixture.data.count, data: Data([0])), NativeMP4ByteRegion(offset: 0, data: Data([255]))] {
            #expect(throws: NativeMediaError.malformedMP4) {
                try NativeMP4.prepareStream(prefix: prefix, totalLength: fixture.data.count, contentKey: key, codec: "h264", auxiliary: [region])
            }
        }
        #expect(throws: NativeMediaError.malformedMP4) { try NativeMP4.prepareStream(prefix: prefix, totalLength: -1, contentKey: key, codec: "h264") }
        #expect(throws: NativeMediaError.malformedMP4) { try NativeMP4.prepareStream(prefix: prefix, totalLength: NativeMediaStore.maximumBytes + 1, contentKey: key, codec: "h264") }
        let tooMuch = Data(count: 8 * 1024 * 1024 + 1)
        #expect(throws: NativeMediaError.malformedMP4) { try NativeMP4.prepareStream(prefix: tooMuch, totalLength: tooMuch.count, contentKey: key, codec: "h264") }
        #expect(throws: NativeMediaError.malformedMP4) {
            try NativeMP4.prepareStream(prefix: prefix, totalLength: tooMuch.count + fixture.data.count, contentKey: key, codec: "h264",
                                        auxiliary: [NativeMP4ByteRegion(offset: prefix.count, data: tooMuch)])
        }
        let outside = streamFixture(payload: cipher, iv: iv, external: true, externalOffset: UInt32(fixture.data.count + 1))
        #expect(throws: NativeMediaError.malformedMP4) {
            try NativeMP4.prepareStream(prefix: outside.data.prefix(outside.prefixCount), totalLength: outside.data.count, contentKey: key, codec: "h264")
        }
    }

    @Test
    func invalidKeysCodecFragmentsAndKeyRotationStillFailClosed() throws {
        let fixture = streamFixture(payload: cipher, iv: iv)
        #expect(throws: NativeMediaError.invalidKey) { try NativeMP4.prepareStream(prefix: fixture.data, totalLength: fixture.data.count, contentKey: nil, codec: "h264") }
        #expect(throws: NativeMediaError.invalidKey) { try NativeMP4.prepareStream(prefix: fixture.data, totalLength: fixture.data.count, contentKey: Data(count: 15), codec: "h264") }
        #expect(throws: NativeMediaError.unsupportedCodec) { try NativeMP4.prepareStream(prefix: fixture.data, totalLength: fixture.data.count, contentKey: key, codec: "bytevc2") }
        let fragmented = fixture.data + streamBox("moof", Data())
        #expect(throws: NativeMediaError.unsupportedEncryption) { try NativeMP4.prepareStream(prefix: fragmented, totalLength: fragmented.count, contentKey: key, codec: "h264") }
        let rotated = streamFixture(payload: cipher, iv: iv, extraTable: streamBox("sbgp", streamU32(0) + Data("seig".utf8)))
        #expect(throws: NativeMediaError.unsupportedEncryption) { try NativeMP4.prepareStream(prefix: rotated.data, totalLength: rotated.data.count, contentKey: key, codec: "h264") }
    }

    @Test
    func cancellationStopsIndexConstructionAndRangeDecryption() async throws {
        let fixture = streamFixture(payload: cipher, iv: iv)
        let plan = try NativeMP4.prepareStream(prefix: fixture.data.prefix(fixture.prefixCount), totalLength: fixture.data.count, contentKey: key, codec: "h264")
        let prepareTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NativeMP4.prepareStream(prefix: fixture.data, totalLength: fixture.data.count, contentKey: key, codec: "h264")
        }
        await #expect(throws: CancellationError.self) { try await prepareTask.value }
        let decryptTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try plan.decrypt(data: fixture.data, offset: 0)
        }
        await #expect(throws: CancellationError.self) { try await decryptTask.value }
    }
}

struct StreamFixture {
    let data: Data
    let prefixCount: Int
    let media: [Range<Int>]
    let auxiliary: Range<Int>?
}

func streamFixture(payload: Data, iv: Data? = nil, originalCodec: String = "avc1", samples: Int = 2,
                           subsamples: [(UInt16, UInt32)]? = nil, external: Bool = false,
                           externalOffset: UInt32? = nil, extraTable: Data = Data()) -> StreamFixture {
    let ftyp = streamBox("ftyp", Data("isom".utf8) + streamU32(0) + Data("isomiso2".utf8))
    var entryBody = Data(count: 78), record = Data()
    if let iv {
        let tenc = streamBox("tenc", streamU32(0) + Data([0, 0, 1, UInt8(iv.count)]) + Data(count: 16))
        entryBody += streamBox("sinf", streamBox("frma", Data(originalCodec.utf8))
            + streamBox("schm", streamU32(0) + Data("cenc".utf8) + streamU32(0x10000)) + streamBox("schi", tenc))
        record = iv
        if let subsamples {
            record += streamU16(UInt16(subsamples.count))
            for (clear, encrypted) in subsamples { record += streamU16(clear) + streamU32(encrypted) }
        }
    }
    let stsd = streamBox("stsd", streamU32(0) + streamU32(1) + streamBox(iv == nil ? originalCodec : "encv", entryBody))
    let stsz = streamBox("stsz", streamU32(0) + streamU32(UInt32(payload.count)) + streamU32(UInt32(samples)))
    let stsc = streamBox("stsc", streamU32(0) + streamU32(1) + streamU32(1) + streamU32(1) + streamU32(1))
    var records = Data(), mediaBytes = Data()
    for _ in 0..<samples { records += record; mediaBytes += payload }
    func movie(mediaStart: Int, auxStart: Int) -> Data {
        var offsets = Data()
        for index in 0..<samples { offsets += streamU32(UInt32(mediaStart + index * payload.count)) }
        let stco = streamBox("stco", streamU32(0) + streamU32(UInt32(samples)) + offsets)
        var aux = Data()
        if iv != nil {
            if external {
                aux = streamBox("saiz", streamU32(0) + Data([UInt8(record.count)]) + streamU32(UInt32(samples)))
                    + streamBox("saio", streamU32(0) + streamU32(1) + streamU32(externalOffset ?? UInt32(auxStart)))
            } else { aux = streamBox("senc", streamU32(subsamples == nil ? 0 : 2) + streamU32(UInt32(samples)) + records) }
        }
        return streamBox("moov", streamBox("trak", streamBox("mdia", streamBox("minf", streamBox("stbl", stsd + stsz + stsc + stco + aux + extraTable)))))
    }
    let prefixCount = ftyp.count + movie(mediaStart: 0, auxStart: 0).count + 8
    let externalBytes = external ? records : Data()
    let mediaStart = prefixCount + externalBytes.count
    let movie = movie(mediaStart: mediaStart, auxStart: prefixCount)
    let data = ftyp + movie + streamBox("mdat", externalBytes + mediaBytes)
    let media = (0..<samples).map { (mediaStart + $0 * payload.count)..<(mediaStart + ($0 + 1) * payload.count) }
    return StreamFixture(data: data, prefixCount: prefixCount, media: media,
                         auxiliary: external ? prefixCount..<(prefixCount + externalBytes.count) : nil)
}

private func streamBox(_ type: String, _ body: Data) -> Data { streamU32(UInt32(body.count + 8)) + Data(type.utf8) + body }
private func streamU32(_ value: UInt32) -> Data { var value = value.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
private func streamU16(_ value: UInt16) -> Data { var value = value.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
private func streamHex(_ string: String) -> Data {
    Data(stride(from: 0, to: string.count, by: 2).map { offset in
        let start = string.index(string.startIndex, offsetBy: offset)
        return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
    })
}
