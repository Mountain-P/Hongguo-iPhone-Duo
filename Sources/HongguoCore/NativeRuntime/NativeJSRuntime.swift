// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import JavaScriptCore

final class NativeJSRuntime: @unchecked Sendable {
    private let identityCache: NativePlaybackIdentityCache?
    init(identityCache: NativePlaybackIdentityCache? = nil) { self.identityCache = identityCache }
    private let queue = DispatchQueue(label: "tw.mountainp.hongguo.native-signer")
    // JavaScriptCore objects are confined to queue, including all native callbacks.
    private var context: JSContext?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var timers: [Int32: DispatchWorkItem] = [:]
    private var completion: CheckedContinuation<String, any Error>?
    private var cancelled = false
    private var finished = false

    func phoneAuth(_ request: NativePhoneAuthRequest) async throws -> String {
        let json = try JSONEncoder().encode(request)
        do {
            return try await run(script: "__startPhoneAuth(" + String(decoding: json, as: UTF8.self) + ")", watchdogSeconds: 16)
        } catch let error as NativeSourceError {
            return error.code == "ETIMEDOUT" ? #"{"error":"ETIMEDOUT"}"# : #"{"error":"ERR_NETWORK"}"#
        }
    }

    func accountLibrary(_ request: AccountLibraryRequest) async throws -> AccountLibraryResponse {
        let raw: String
        do {
            raw = try await run(script: "__startAccountLibrary(" + String(decoding: request.json(), as: UTF8.self) + ")", watchdogSeconds: 21)
        } catch let error as NativeSourceError {
            throw AccountLibraryError(code: error.code == "ETIMEDOUT" ? "ETIMEDOUT" : "ERR_NETWORK")
        }
        try Task.checkCancellation()
        return try AccountLibraryParser.response(raw, operation: request.operation, accountID: request.accountID)
    }

    func newReleases(category: NewReleaseCategory) async throws -> DiscoveryPage {
        let arguments = try JSONSerialization.data(withJSONObject: [category.rawValue])
        let raw: String
        do {
            raw = try await run(script: "__startNewReleases(..." + String(decoding: arguments, as: UTF8.self) + ")", watchdogSeconds: 8)
        } catch let error as NativeSourceError {
            throw error.code == "ETIMEDOUT" ? NewReleaseError.timeout : NewReleaseError.network
        }
        try Task.checkCancellation()
        return try NativeNewReleaseParser.parse(raw)
    }

    func resolve(episodeID: String, contentType: String, quality preference: NativePlaybackQuality = .automatic,
                 offlineDirect: Bool = false) async throws -> NativeMediaSource {
        let arguments = try JSONSerialization.data(withJSONObject: [episodeID, contentType, preference.sourcePreference.rawValue, offlineDirect])
        let raw = try await run(script: "__startResolve(..." + String(decoding: arguments, as: UTF8.self) + ")")
        try Task.checkCancellation()
        return try Self.parseSource(raw, preference: preference, offlineDirect: offlineDirect)
    }

    static func parseSource(_ raw: String, preference: NativePlaybackQuality, offlineDirect: Bool) throws -> NativeMediaSource {
        guard let data = raw.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeSourceError(code: "INVALID_RESPONSE") }
        if let code = object["error"] as? String { throw NativeSourceError(code: code) }
        guard let address = object["url"] as? String, let url = URL(string: address), Self.allowedMediaURL(url),
              let userAgent = object["userAgent"] as? String, userAgent.utf8.count < 1024, !userAgent.contains("\n"), !userAgent.contains("\r"),
              let codec = object["codec"] as? String, ["h264", "avc", "avc1", "hevc", "h265", "hvc1", "hev1"].contains(codec),
              let quality = object["quality"] as? String, quality.utf8.count <= 128,
              object["preference"] as? String == preference.sourcePreference.rawValue else { throw NativeSourceError(code: "NO_COMPATIBLE_SOURCE") }
        let key: Data?
        if let hex = object["contentKey"] as? String, !hex.isEmpty {
            guard hex.range(of: #"^[0-9a-fA-F]{32}$"#, options: .regularExpression) != nil else { throw NativeSourceError(code: "INVALID_RESPONSE") }
            key = Data(stride(from: 0, to: 32, by: 2).map { offset in
                let first = hex.index(hex.startIndex, offsetBy: offset), last = hex.index(first, offsetBy: 2)
                return UInt8(hex[first..<last], radix: 16)!
            })
        } else { key = nil }
        if offlineDirect, key != nil { throw NativeSourceError(code: "OFFLINE_CLEAR_UNAVAILABLE") }
        func dimension(_ key: String) -> Int? {
            guard let number = object[key] as? NSNumber, (1...16_384).contains(number.intValue) else { return nil }
            return number.intValue
        }
        let qualityFallback = object["qualityFallback"] as? Bool ?? false
        let width = dimension("width"), height = dimension("height")
        func source(at address: URL, alternates: [NativeMediaSource] = []) -> NativeMediaSource {
            NativeMediaSource(url: address, contentKey: key, userAgent: userAgent, codec: codec, quality: quality,
                              preference: preference, qualityFallback: qualityFallback,
                              width: width, height: height, alternateSources: alternates)
        }
        guard !offlineDirect, let alternateURLs = object["alternateURLs"] as? [String] else { return source(at: url) }
        var seen = Set([url])
        let alternates = alternateURLs.prefix(2).compactMap { address -> NativeMediaSource? in
            guard let alternate = URL(string: address), NativeMediaPolicy.allows(alternate),
                  seen.insert(alternate).inserted else { return nil }
            return source(at: alternate)
        }
        return source(at: url, alternates: alternates)
    }

    static func allowedMediaURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["qznovelvod.com", "fqnovelvod.com", "douyinvod.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Test-only entry point: uses the real bundled runtime and native adapters.
    func evaluateForTesting(_ expression: String) async throws -> String {
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: [expression]), as: UTF8.self)
        return try await run(script: "Promise.resolve().then(() => eval(" + literal + "[0])).then(value => _nativeComplete(JSON.stringify(value)), error => _nativeComplete(JSON.stringify({error:String(error.code || error.name || 'ERROR')})))", testing: true)
    }

    private func run(script: String, testing: Bool = false, watchdogSeconds: Double = 31) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                    guard !finished, completion == nil else { continuation.resume(throwing: NativeSourceError(code: "RUNTIME_REUSE")); return }
                    completion = continuation
                    do {
                        try bootstrap(testing: testing, watchdogSeconds: watchdogSeconds)
                        context?.evaluateScript(script)
                        if context?.exception != nil { complete(.failure(NativeSourceError(code: "RUNTIME_SCRIPT"))) }
                    } catch { complete(.failure(error)) }
                }
            }
        } onCancel: { self.queue.async { self.cancel() } }
    }

    private func bootstrap(testing: Bool, watchdogSeconds: Double) throws {
        guard let context = JSContext() else { throw NativeSourceError(code: "RUNTIME_UNAVAILABLE") }
        self.context = context
        let invoke: @convention(block) (String, String) -> String = { operation, json in NativeCrypto.invoke(operation, json: json) }
        let http: @convention(block) (String, String) -> Void = { [weak self] id, json in self?.startHTTP(id, json: json) }
        let cancelHTTP: @convention(block) (String) -> Void = { [weak self] id in self?.tasks.removeValue(forKey: id)?.cancel() }
        let schedule: @convention(block) (Int32, Double) -> Void = { [weak self] id, delay in
            guard let self else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                self.timers.removeValue(forKey: id)
                self.context?.objectForKeyedSubscript("__timerFire")?.call(withArguments: [id])
            }
            self.timers[id] = work
            self.queue.asyncAfter(deadline: .now() + max(0, min(60_000, delay)) / 1000, execute: work)
        }
        let clear: @convention(block) (Int32) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
        let complete: @convention(block) (String) -> Void = { [weak self] value in self?.complete(.success(value)) }
        let cache = identityCache ?? (testing ? NativePlaybackIdentityCache() : .shared)
        let readIdentity: @convention(block) (String) -> String = { cache.read(scope: $0) }
        let writeIdentity: @convention(block) (String, String) -> Bool = { [weak self] scope, json in
            guard let self, !self.cancelled, !self.finished else { return false }
            return cache.write(scope: scope, json: json)
        }
        context.setObject(invoke, forKeyedSubscript: "_nativeInvoke" as NSString)
        context.setObject(http, forKeyedSubscript: "_nativeHTTP" as NSString)
        context.setObject(cancelHTTP, forKeyedSubscript: "_nativeCancelHTTP" as NSString)
        context.setObject(schedule, forKeyedSubscript: "_nativeSchedule" as NSString)
        context.setObject(clear, forKeyedSubscript: "_nativeClearTimer" as NSString)
        context.setObject(complete, forKeyedSubscript: "_nativeComplete" as NSString)
        context.setObject(readIdentity, forKeyedSubscript: "_nativeReadPlaybackIdentity" as NSString)
        context.setObject(writeIdentity, forKeyedSubscript: "_nativeWritePlaybackIdentity" as NSString)
        let modules = ["buffer": "buffer/index", "base64-js": "base64-js/index", "ieee754": "ieee754/index",
                       "app-source": "app-source", "playback-device": "playback-device", "playback-recovery": "playback-recovery",
                       "playback-signature": "playback-signature", "sm3": "sm3", "download-quality": "download-quality",
                       "new-releases": "new-releases", "account-library": "account-library", "native-phone-auth": "native-phone-auth"]
        var sources: [String: String] = [:]
        for (name, path) in modules { sources[name] = try resource(path) }
        if testing { sources["app-source"]! += "\nmodule.exports.audit = { hashF13, sm3, helios, xGorgon, branchOf, playbackRequest, primaryPlaybackRequest, consumeAppPlayResponse, parseAppPlayModel, playbackDevice };" }
        context.setObject(sources, forKeyedSubscript: "__moduleSources" as NSString)
        context.evaluateScript(try resource("runtime"))
        guard context.exception == nil else { throw NativeSourceError(code: "RUNTIME_BOOTSTRAP") }
        // Native watchdog also bounds failures before JS installs its deadline.
        let timeout = DispatchWorkItem { [weak self] in self?.complete(.failure(NativeSourceError(code: "ETIMEDOUT"))) }
        timers[-1] = timeout; queue.asyncAfter(deadline: .now() + watchdogSeconds, execute: timeout)
    }

    private func resource(_ path: String) throws -> String {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("PlaybackAssets"),
              let source = try? String(contentsOf: root.appendingPathComponent(path + ".js"), encoding: .utf8) else { throw NativeSourceError(code: "RUNTIME_RESOURCE") }
        return source
    }

    private func startHTTP(_ id: String, json: String) {
        guard !finished else { return }
        tasks[id] = Task { [weak self] in
            let value = await NativeHTTP.perform(json)
            self?.queue.async { [weak self] in
                guard let self, !self.finished else { return }
                self.tasks.removeValue(forKey: id)
                self.context?.objectForKeyedSubscript("__httpDone")?.call(withArguments: [id, value])
            }
        }
    }

    private func cancel() {
        cancelled = true
        context?.objectForKeyedSubscript("__cancelResolve")?.call(withArguments: [])
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<String, any Error>) {
        guard !finished else { return }; finished = true
        let continuation = completion; completion = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        timers.values.forEach { $0.cancel() }; timers.removeAll()
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else { continuation?.resume(with: result) }
        // Release the context after its current native callback unwinds.
        queue.async { [self] in context = nil }
    }
}
