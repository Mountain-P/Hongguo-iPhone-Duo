// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import CommonCrypto
import Security
import zlib

enum NativeCrypto {
    static func invoke(_ operation: String, json: String) -> String {
        do {
            guard let data = json.data(using: .utf8), data.count <= 6 * 1024 * 1024,
                  let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeSourceError(code: "CRYPTO_INPUT") }
            let value = try perform(operation, args)
            return String(decoding: try JSONSerialization.data(withJSONObject: ["value": value]), as: UTF8.self)
        } catch { return #"{"error":"NATIVE_OPERATION_FAILED"}"# }
    }

    static func perform(_ operation: String, _ args: [String: Any]) throws -> Any {
        func bytes(_ name: String) throws -> Data {
            guard let raw = args[name] as? String, let value = Data(base64Encoded: raw), value.count <= 2 * 1024 * 1024 else { throw NativeSourceError(code: "CRYPTO_INPUT") }
            return value
        }
        switch operation {
        case "hash":
            let input = try bytes("data")
            switch args["algorithm"] as? String {
            case "md5": return Data(Insecure.MD5.hash(data: input)).base64EncodedString()
            case "sha512": return Data(SHA512.hash(data: input)).base64EncodedString()
            case "sha256": return Data(SHA256.hash(data: input)).base64EncodedString()
            default: throw NativeSourceError(code: "CRYPTO_INPUT")
            }
        case "random":
            guard let count = args["count"] as? Int, (0...1024 * 1024).contains(count) else { throw NativeSourceError(code: "CRYPTO_INPUT") }
            if count == 0 { return "" }
            var result = Data(count: count)
            let status = result.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
            guard status == errSecSuccess else { throw NativeSourceError(code: "CRYPTO_RANDOM") }
            return result.base64EncodedString()
        case "uuid": return UUID().uuidString.lowercased()
        case "cipher":
            return try cipher(try bytes("data"), key: try bytes("key"), iv: try bytes("iv"), algorithm: args["algorithm"] as? String ?? "", decrypt: args["decrypt"] as? Bool ?? false, padding: args["padding"] as? Bool ?? true).base64EncodedString()
        case "gzip": return try gzip(try bytes("data")).base64EncodedString()
        case "gunzip": return try gunzip(try bytes("data")).base64EncodedString()
        case "url":
            guard let raw = args["value"] as? String, raw.count <= 32768,
                  let url = URL(string: raw, relativeTo: (args["base"] as? String).flatMap(URL.init(string:)))?.absoluteURL,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: true), let scheme = components.scheme, let host = components.host else { throw NativeSourceError(code: "INVALID_URL") }
            return ["href": url.absoluteString, "protocol": scheme.lowercased() + ":", "hostname": host.lowercased(),
                    "username": components.user ?? "", "password": components.password ?? "", "port": components.port.map(String.init) ?? "",
                    "pathname": components.path, "search": components.percentEncodedQuery.map { "?" + $0 } ?? ""]
        default: throw NativeSourceError(code: "NATIVE_OPERATION")
        }
    }

    static func cipher(_ data: Data, key: Data, iv: Data, algorithm: String, decrypt: Bool, padding: Bool) throws -> Data {
        let mode: CCMode
        switch algorithm {
        case "aes-128-cbc": mode = CCMode(kCCModeCBC)
        case "aes-128-ctr": mode = CCMode(kCCModeCTR)
        case "aes-128-ecb": mode = CCMode(kCCModeECB)
        default: throw NativeSourceError(code: "CRYPTO_INPUT")
        }
        guard key.count == 16, mode == CCMode(kCCModeECB) || iv.count == 16 else { throw NativeSourceError(code: "CRYPTO_INPUT") }
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in
            CCCryptorCreateWithMode(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), mode, CCAlgorithm(kCCAlgorithmAES),
                CCPadding(padding && mode != CCMode(kCCModeCTR) ? ccPKCS7Padding : ccNoPadding), ivBytes.baseAddress,
                keyBytes.baseAddress, key.count, nil, 0, 0, CCModeOptions(mode == CCMode(kCCModeCTR) ? kCCModeOptionCTR_BE : 0), &cryptor)
        } }
        guard status == kCCSuccess, let cryptor else { throw NativeSourceError(code: "CRYPTO_CIPHER") }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: data.count + kCCBlockSizeAES128 * 2)
        var moved = 0, finalMoved = 0
        let capacity = output.count
        let update = data.withUnsafeBytes { source in output.withUnsafeMutableBytes { target in
            CCCryptorUpdate(cryptor, source.baseAddress, data.count, target.baseAddress, capacity, &moved)
        } }
        guard update == kCCSuccess else { throw NativeSourceError(code: "CRYPTO_CIPHER") }
        let final = output.withUnsafeMutableBytes { target in CCCryptorFinal(cryptor, target.baseAddress!.advanced(by: moved), capacity - moved, &finalMoved) }
        guard final == kCCSuccess else { throw NativeSourceError(code: "CRYPTO_CIPHER") }
        output.count = moved + finalMoved
        return output
    }

    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw NativeSourceError(code: "GZIP") }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(compressBound(uLong(data.count))) + 64)
        let count = output.count
        let status = data.withUnsafeBytes { input in output.withUnsafeMutableBytes { target in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(count)
            return deflate(&stream, Z_FINISH)
        } }
        guard status == Z_STREAM_END else { throw NativeSourceError(code: "GZIP") }
        output.count = Int(stream.total_out)
        return output
    }

    static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw NativeSourceError(code: "GZIP") }
        defer { inflateEnd(&stream) }
        var output = Data(count: 2 * 1024 * 1024)
        let count = output.count
        let status = data.withUnsafeBytes { input in output.withUnsafeMutableBytes { target in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(data.count)
            stream.next_out = target.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(count)
            return inflate(&stream, Z_FINISH)
        } }
        guard status == Z_STREAM_END else { throw NativeSourceError(code: "GZIP") }
        output.count = Int(stream.total_out)
        return output
    }
}
