import Foundation
import Testing
@testable import HongguoCore

/// Synthetic BMFF structures and public AES test vectors. No source-platform media or keys are stored here.
struct NativeMP4Tests {
    // NIST SP 800-38A F.5 AES-128-CTR key, plaintext, counter and ciphertext.
    private let key = fixtureHex("2b7e151628aed2a6abf7158809cf4f3c")
    private let plaintext = fixtureHex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
    private let counter = fixtureHex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
    private let ciphertext = fixtureHex("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff5ae4df3edbd5d35e5b4f09020db03eab1e031dda2fbe03d1792170a0f3009cee")

    @Test
    func clearMP4RemainsByteIdentical() throws {
        let fixture = makeMP4Fixture(payload: plaintext)
        let output = try NativeMP4.decrypt(data: fixture.data, contentKey: nil, codec: "h264")
        #expect(output == fixture.data)
    }

    @Test
    func sixteenByteIVMatchesNISTAndRestoresHEVCSampleEntry() throws {
        let fixture = makeMP4Fixture(payload: ciphertext, iv: counter, originalCodec: "hvc1")
        let output = try NativeMP4.decrypt(data: fixture.data, contentKey: key, codec: "hevc")
        #expect(output.count == fixture.data.count)
        #expect(output.subdata(in: fixture.media) == plaintext)
        #expect(fixtureType(output, at: fixture.entryType) == "hvc1")
        try expectMetadataRemoved(output, original: fixture.data, type: "sinf")
        try expectMetadataRemoved(output, original: fixture.data, type: "senc")
        // Offset tables and media start do not change while protection boxes become padding.
        #expect(try fixtureBox(output, "stco") == fixtureBox(fixture.data, "stco"))
    }

    @Test
    func eightByteIVPadsCounterWithZerosAndRestoresAVCEntry() throws {
        // Independently generated with OpenSSL enc -aes-128-ctr, the public key above,
        // and IV 00010203040506070000000000000000. This is not an implementation round trip.
        let encrypted = fixtureHex("19ce20015553385e50b3eb4c2523e4390a1c99741d0d6cb96780e3fcf631a88debc1aa3eeb35fe73fe5670c274c2524f383a5868d9639126bcb6ec4fee3b936b")
        let fixture = makeMP4Fixture(payload: encrypted, iv: fixtureHex("0001020304050607"))
        let output = try NativeMP4.decrypt(data: fixture.data, contentKey: key, codec: "h264")
        #expect(output.count == fixture.data.count)
        #expect(output.subdata(in: fixture.media) == plaintext)
        #expect(fixtureType(output, at: fixture.entryType) == "avc1")
    }

    @Test
    func subsamplesLeaveClearBytesUntouchedAndContinueCipherAcrossRanges() throws {
        // OpenSSL encrypted the concatenation NIST?segment-number-02 once, then the
        // clear CLR/PASS prefixes were interleaved. Neither range is block-aligned.
        let encrypted = fixtureHex("a2c58c27a71319d79fb77801c7f0d489544e0e115741")
        let payload = Data("CLR".utf8) + encrypted.prefix(5) + Data("PASS".utf8) + encrypted.dropFirst(5)
        let expected = Data("CLRNIST?PASSsegment-number-02".utf8)
        let fixture = makeMP4Fixture(payload: payload, iv: counter, subsamples: [(3, 5), (4, 17)])
        let output = try NativeMP4.decrypt(data: fixture.data, contentKey: key, codec: "h264")
        #expect(output.subdata(in: fixture.media) == expected)
        #expect(output.count == fixture.data.count)
    }

    @Test
    func externalAuxiliaryRecordsUseSaizSaioWithoutChangingChunkOffsets() throws {
        // CENC permits auxiliary records outside senc, including in mdat before the samples.
        let fixture = makeMP4Fixture(payload: ciphertext, iv: counter, externalAuxiliary: true)
        let output = try NativeMP4.decrypt(data: fixture.data, contentKey: key, codec: "h264")
        #expect(output.subdata(in: fixture.media) == plaintext)
        #expect(output.count == fixture.data.count)
        #expect(try fixtureBox(output, "stco") == fixtureBox(fixture.data, "stco"))
        try expectMetadataRemoved(output, original: fixture.data, type: "saiz")
        try expectMetadataRemoved(output, original: fixture.data, type: "saio")
    }

    @Test
    func encryptedSamplesRequireKeyAndCompleteMetadata() throws {
        let fixture = makeMP4Fixture(payload: ciphertext, iv: counter)
        #expect(throws: NativeMediaError.invalidKey) { try NativeMP4.decrypt(data: fixture.data, contentKey: nil, codec: "h264") }
        #expect(throws: NativeMediaError.invalidKey) { try NativeMP4.decrypt(data: fixture.data, contentKey: Data(repeating: 0, count: 15), codec: "h264") }
        let missing = makeMP4Fixture(payload: ciphertext, iv: counter, includeSenc: false)
        #expect(throws: NativeMediaError.missingEncryptionMetadata) { try NativeMP4.decrypt(data: missing.data, contentKey: key, codec: "h264") }
        let mismatchedAux = makeMP4Fixture(payload: ciphertext, iv: counter, auxiliarySize: 8)
        #expect(throws: NativeMediaError.malformedMP4) { try NativeMP4.decrypt(data: mismatchedAux.data, contentKey: key, codec: "h264") }
    }

    @Test
    func malformedBoxesAndSamplesOutsideMdatAreRejected() throws {
        let fixture = makeMP4Fixture(payload: ciphertext, iv: counter)
        var undersizedBox = fixture.data
        undersizedBox.replaceSubrange(0..<4, with: fixtureU32(7))
        #expect(throws: NativeMediaError.malformedMP4) { try NativeMP4.decrypt(data: undersizedBox, contentKey: key, codec: "h264") }
        #expect(throws: NativeMediaError.malformedMP4) { try NativeMP4.decrypt(data: Data(fixture.data.dropLast()), contentKey: key, codec: "h264") }
        let outside = makeMP4Fixture(payload: ciphertext, iv: counter, sampleOffset: 0)
        #expect(throws: NativeMediaError.malformedMP4) { try NativeMP4.decrypt(data: outside.data, contentKey: key, codec: "h264") }
        let overrun = makeMP4Fixture(payload: ciphertext, iv: counter, sampleSize: ciphertext.count + 1)
        #expect(throws: NativeMediaError.malformedMP4) { try NativeMP4.decrypt(data: overrun.data, contentKey: key, codec: "h264") }
        let invalidSubsamples = makeMP4Fixture(payload: ciphertext, iv: counter, subsamples: [(0, UInt32(ciphertext.count + 1))])
        #expect(throws: NativeMediaError.malformedMP4) { try NativeMP4.decrypt(data: invalidSubsamples.data, contentKey: key, codec: "h264") }
    }

    @Test
    func unsupportedCodecSchemeAndFragmentedLayoutFailClosed() throws {
        let clear = makeMP4Fixture(payload: plaintext)
        #expect(throws: NativeMediaError.unsupportedCodec) { try NativeMP4.decrypt(data: clear.data, contentKey: nil, codec: "bytevc2") }
        #expect(throws: NativeMediaError.unsupportedCodec) { try NativeMP4.decrypt(data: clear.data, contentKey: nil, codec: "hevc") }
        let cbcs = makeMP4Fixture(payload: ciphertext, iv: counter, scheme: "cbcs")
        #expect(throws: NativeMediaError.unsupportedEncryption) { try NativeMP4.decrypt(data: cbcs.data, contentKey: key, codec: "h264") }
        let fragmented = clear.data + fixtureBox("moof", Data())
        #expect(throws: NativeMediaError.unsupportedEncryption) { try NativeMP4.decrypt(data: fragmented, contentKey: key, codec: "h264") }
    }
}

private struct MP4Fixture {
    let data: Data
    let media: Range<Int>
    let entryType: Int
}

private func makeMP4Fixture(payload: Data, iv: Data? = nil, originalCodec: String = "avc1",
                            subsamples: [(UInt16, UInt32)]? = nil, sampleOffset: Int? = nil, sampleSize: Int? = nil,
                            includeSenc: Bool = true, auxiliarySize: UInt8? = nil, scheme: String = "cenc",
                            externalAuxiliary: Bool = false) -> MP4Fixture {
    let ftyp = fixtureBox("ftyp", Data("isom".utf8) + fixtureU32(0) + Data("isomiso2".utf8))
    var entryBody = Data(repeating: 0, count: 78)
    if let iv {
        let frma = fixtureBox("frma", Data(originalCodec.utf8))
        let schm = fixtureBox("schm", fixtureU32(0) + Data(scheme.utf8) + fixtureU32(0x0001_0000))
        let tenc = fixtureBox("tenc", fixtureU32(0) + Data([0, 0, 1, UInt8(iv.count)]) + Data(repeating: 0, count: 16))
        entryBody += fixtureBox("sinf", frma + schm + fixtureBox("schi", tenc))
    }
    let entry = fixtureBox(iv == nil ? originalCodec : "encv", entryBody)
    let stsd = fixtureBox("stsd", fixtureU32(0) + fixtureU32(1) + entry)
    let stsz = fixtureBox("stsz", fixtureU32(0) + fixtureU32(0) + fixtureU32(1) + fixtureU32(UInt32(sampleSize ?? payload.count)))
    let stsc = fixtureBox("stsc", fixtureU32(0) + fixtureU32(1) + fixtureU32(1) + fixtureU32(1) + fixtureU32(1))
    var auxiliary = Data()
    var record = Data()
    if let iv {
        record = iv
        if let subsamples {
            record += fixtureU16(UInt16(subsamples.count))
            for (clear, encrypted) in subsamples { record += fixtureU16(clear) + fixtureU32(encrypted) }
        }
        if includeSenc && !externalAuxiliary {
            auxiliary += fixtureBox("senc", fixtureU32(subsamples == nil ? 0 : 2) + fixtureU32(1) + record)
        }
    }
    if let auxiliarySize = auxiliarySize ?? (externalAuxiliary ? UInt8(record.count) : nil) {
        auxiliary += fixtureBox("saiz", fixtureU32(0) + Data([auxiliarySize]) + fixtureU32(1))
    }
    func movie(offset: Int, auxiliaryOffset: Int = 0) -> Data {
        let stco = fixtureBox("stco", fixtureU32(0) + fixtureU32(1) + fixtureU32(UInt32(offset)))
        let saio = externalAuxiliary ? fixtureBox("saio", fixtureU32(0) + fixtureU32(1) + fixtureU32(UInt32(auxiliaryOffset))) : Data()
        let table = fixtureBox("stbl", stsd + stsz + stsc + stco + auxiliary + saio)
        return fixtureBox("moov", fixtureBox("trak", fixtureBox("mdia", fixtureBox("minf", table))))
    }
    let auxStart = ftyp.count + movie(offset: 0).count + 8
    let externalRecord = externalAuxiliary ? record : Data()
    let mediaStart = auxStart + externalRecord.count
    let data = ftyp + movie(offset: sampleOffset ?? mediaStart, auxiliaryOffset: auxStart) + fixtureBox("mdat", externalRecord + payload)
    let entryType = data.range(of: Data((iv == nil ? originalCodec : "encv").utf8))!.lowerBound
    return MP4Fixture(data: data, media: mediaStart..<(mediaStart + payload.count), entryType: entryType)
}

private func fixtureBox(_ type: String, _ body: Data) -> Data {
    precondition(type.utf8.count == 4)
    return fixtureU32(UInt32(body.count + 8)) + Data(type.utf8) + body
}

private func fixtureU16(_ value: UInt16) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private func fixtureU32(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private func fixtureHex(_ string: String) -> Data {
    Data(stride(from: 0, to: string.utf8.count, by: 2).map { offset in
        let first = string.index(string.startIndex, offsetBy: offset)
        return UInt8(string[first..<string.index(first, offsetBy: 2)], radix: 16)!
    })
}

private func fixtureType(_ data: Data, at offset: Int) -> String {
    String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
}

private func fixtureBox(_ data: Data, _ type: String) throws -> Data {
    let typeStart = try #require(data.range(of: Data(type.utf8))?.lowerBound)
    let start = typeStart - 4
    let size = data.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: start, as: UInt32.self))) }
    return data.subdata(in: start..<(start + size))
}

private func expectMetadataRemoved(_ output: Data, original: Data, type: String) throws {
    let typeStart = try #require(original.range(of: Data(type.utf8))?.lowerBound)
    let originalBox = try fixtureBox(original, type)
    #expect(fixtureType(output, at: typeStart) == "free")
    #expect(output[(typeStart + 4)..<(typeStart - 4 + originalBox.count)].allSatisfy { $0 == 0 })
}
