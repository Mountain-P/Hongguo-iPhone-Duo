// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private actor QualitySourceCalls {
    private(set) var values: [NativePlaybackQuality] = []
    func append(_ quality: NativePlaybackQuality) -> Int { values.append(quality); return values.count }
}

struct NativePlaybackQualityTests {
    @Test @MainActor func preferenceDefaultsAndPersistsOnlyTheChosenPolicy() throws {
        let name = "NativePlaybackQualityTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NativePlaybackQualityStore(defaults: defaults)
        #expect(store.load() == .automatic)
        #expect(NativePlaybackQuality.automatic.title == "自動（最佳可用）")
        store.save(.dataSaver)
        #expect(NativePlaybackQualityStore(defaults: defaults).load() == .dataSaver)
        store.save(.automatic)
        #expect(store.load() == .automatic)
        defaults.set("invented-480p", forKey: NativePlaybackQualityStore.key)
        #expect(store.load() == .automatic)
    }

    @Test func adaptivePolicyUsesSupportedBestSourceRequestAndRetainsItsSeparatePreference() throws {
        let raw = #"{"url":"https://unit.fqnovelvod.com/video.mp4","userAgent":"Fixture","codec":"h264","quality":"1080p","preference":"automatic","width":1080,"height":1920}"#
        #expect(NativePlaybackQuality.smooth.sourcePreference == .automatic)
        let source = try NativeJSRuntime.parseSource(raw, preference: .smooth, offlineDirect: false)
        #expect(source.preference == .smooth)
        #expect(source.width == 1080)
        #expect(throws: (any Error).self) { try NativeJSRuntime.parseSource(raw, preference: .dataSaver, offlineDirect: false) }
    }

    @Test func sourceCacheSeparatesPoliciesEvenWhenProviderReturnsTheSameVariant() async throws {
        let calls = QualitySourceCalls()
        let resolver = NativeSourceResolver(resolveQuality: { _, _, quality in
            let count = await calls.append(quality)
            return qualitySource(quality, label: String(count))
        })
        #expect(try await resolver.resolve(episodeID: "100").quality == "1")
        #expect(try await resolver.resolve(episodeID: "100", quality: .dataSaver).quality == "2")
        #expect(try await resolver.resolve(episodeID: "100").quality == "1")
        #expect(try await resolver.resolve(episodeID: "100", quality: .dataSaver).quality == "2")
        #expect(try await resolver.resolve(episodeID: "100", fresh: true, quality: .dataSaver).quality == "3")
        #expect(try await resolver.resolve(episodeID: "100").quality == "1")
        #expect(await calls.values == [.automatic, .dataSaver, .dataSaver])
    }

    @Test func cancelledPolicyCannotPopulateOrInvalidateTheOtherPolicyCache() async throws {
        let calls = QualitySourceCalls()
        let resolver = NativeSourceResolver(resolveQuality: { _, _, quality in
            let count = await calls.append(quality)
            if quality == .dataSaver { try await Task.sleep(for: .seconds(10)) }
            return qualitySource(quality, label: String(count))
        })
        let automatic = try await resolver.resolve(episodeID: "100")
        let pending = Task { try await resolver.resolve(episodeID: "100", quality: .dataSaver) }
        for _ in 0..<100 {
            if await calls.values.count > 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await calls.values.count == 2)
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await resolver.resolve(episodeID: "100").quality == automatic.quality)
        #expect(await calls.values.count == 2)
    }

    @Test func wrongPolicyResponseIsRejectedAndNeverCached() async throws {
        let calls = QualitySourceCalls()
        let resolver = NativeSourceResolver(resolveQuality: { _, _, quality in
            _ = await calls.append(quality)
            return qualitySource(.automatic)
        })
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) {
                try await resolver.resolve(episodeID: "100", quality: .dataSaver)
            }
        }
        #expect(await calls.values == [.dataSaver, .dataSaver])
    }

    @Test func bundledSelectorUsesActualLowestCompatibleDimensionsAndKeepsAutomaticBest() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (() => {
          const parse = require('app-source').audit.parseAppPlayModel;
          const row = (short, codec='h264') => ({ main_url:`https://unit.fqnovelvod.com/${short}-${codec}.mp4`,
            codec_type:codec, vwidth:short, vheight:short*2, quality_desc:`${short}p`, encrypt:false });
          const model={video_id:'fixture',video_duration:10,video_list:{a:row(1080),b:row(360),c:row(720),d:row(240,'bytevc2')}};
          const brief = preference => { const s=parse(model,'fixture',{quality:'auto',playbackQuality:preference},true);
            return {width:s.width,height:s.height,codec:s.codec,quality:s.quality,fallback:s.qualityFallback}; };
          return {automatic:brief('automatic'),saver:brief('dataSaver')};
        })()
        """#)
        let object = try qualityDictionary(result)
        let automatic = try #require(object["automatic"] as? [String: Any])
        let saver = try #require(object["saver"] as? [String: Any])
        #expect(automatic["width"] as? Int == 1080)
        #expect(automatic["quality"] as? String == "1080p")
        #expect(saver["width"] as? Int == 360)
        #expect(saver["height"] as? Int == 720)
        #expect(saver["quality"] as? String == "360p")
        #expect(saver["codec"] as? String == "h264")
        #expect(saver["fallback"] as? Bool == false)
    }

    @Test func bundledResolveEntryPropagatesBothPoliciesAndRejectsInvalidInputBeforeNetwork() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (async () => {
          const originalRequire=globalThis.require, originalComplete=globalThis._nativeComplete;
          const calls=[];
          globalThis.require = name => name==='app-source' ? {fetchAppPlayUrl: async (id, options) => {
            calls.push({policy:options.playbackQuality,quality:options.quality});
            return {url:'https://unit.fqnovelvod.com/fixture.mp4',userAgent:'Fixture',codec:'hevc',quality:'360p',
              width:360,height:640,qualityFallback:false};
          }} : originalRequire(name);
          const run = policy => new Promise(resolve => {
            globalThis._nativeComplete = raw => resolve(JSON.parse(raw));
            __startResolve('100','1004',policy);
          });
          try {
            const invalid=await run('invented-480p'), invalidCalls=calls.length;
            const automatic=await run('automatic'), saver=await run('dataSaver');
            return {calls,invalidCalls,error:invalid.error,automatic:automatic.preference,saver:saver.preference,width:saver.width};
          } finally { globalThis.require=originalRequire; globalThis._nativeComplete=originalComplete; }
        })()
        """#)
        let object = try qualityDictionary(result)
        #expect(object["invalidCalls"] as? Int == 0)
        #expect(object["error"] as? String == "APP_INPUT")
        #expect(object["automatic"] as? String == "automatic")
        #expect(object["saver"] as? String == "dataSaver")
        #expect(object["width"] as? Int == 360)
        let calls = try #require(object["calls"] as? [[String: String]])
        #expect(calls == [["policy": "automatic", "quality": "auto"], ["policy": "dataSaver", "quality": "auto"]])
    }

    @Test func bundledResolveKeepsOnlyTwoValidatedMirrorsFromTheSelectedRow() async throws {
        let raw = try await NativeJSRuntime().evaluateForTesting(#"""
        (() => {
          const app = require('app-source');
          const main = 'https://primary.fqnovelvod.com/video.mp4';
          const first = 'https://mirror.qznovelvod.com/video.mp4';
          const row = { main_url:main, backup_url:first, codec_type:'h264',
            vwidth:1080, vheight:1920, quality_desc:'1080p', encrypt:false,
            backup_url_list:[main,first,'https://blocked.invalid/video.mp4',
              'https://mirror.douyinvod.com/video.mp4','https://extra.fqnovelvod.com/video.mp4'] };
          const other = { ...row, main_url:'https://other.fqnovelvod.com/video.mp4',
            backup_url_list:[], backup_url:undefined, codec_type:'hevc' };
          app.fetchAppPlayUrl = async (id, options) => {
            const oneMirror = { ...row, backup_url_list:[] };
            const sparse = app.audit.parseAppPlayModel({video_list:{oneMirror,other}}, id, options, true);
            if (sparse.alternateURLs.length !== 1 || sparse.alternateURLs[0] !== first || sparse.variants.length !== 3) {
              throw Object.assign(new Error('fixture'), {code:'WRONG_RENDITION'});
            }
            return app.audit.parseAppPlayModel({video_list:{row,other}}, id, options, true);
          };
          __startResolve('100', '1004');
          return new Promise(() => {});
        })()
        """#)
        let source = try NativeJSRuntime.parseSource(raw, preference: .automatic, offlineDirect: false)
        #expect(source.url.host == "primary.fqnovelvod.com")
        #expect(source.alternateSources.compactMap { $0.url.host } == ["mirror.qznovelvod.com", "mirror.douyinvod.com"])
        for alternate in source.alternateSources {
            #expect(alternate.codec == source.codec)
            #expect(alternate.width == source.width)
            #expect(alternate.height == source.height)
            #expect(alternate.alternateSources.isEmpty)
        }
        #expect(try NativeJSRuntime.parseSource(raw, preference: .automatic, offlineDirect: true).alternateSources.isEmpty)

        var invalid = try qualityDictionary(raw)
        invalid["alternateURLs"] = [source.url.absoluteString, "https://unknown.invalid/video.mp4"]
        let invalidRaw = String(decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)
        #expect(try NativeJSRuntime.parseSource(invalidRaw, preference: .automatic, offlineDirect: false).alternateSources.isEmpty)
    }

    @Test func singleTierUnknownSizeAndInvalidLowerSourceFallBackWithoutInventingResolution() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (() => {
          const parse=require('app-source').audit.parseAppPlayModel;
          const high={main_url:'https://unit.fqnovelvod.com/high.mp4',codec_type:'h264',width:1080,height:1920,quality_desc:'1080p',encrypt:false};
          const low={...high,width:360,height:640,quality_desc:'360p',main_url:'https://blocked.invalid/low.mp4'};
          const brief = rows => { const s=parse({video_list:rows},'fixture',{quality:'auto',playbackQuality:'dataSaver'},true);
            return {width:s.width ?? null,quality:s.quality,fallback:s.qualityFallback,high:s.url.endsWith('/high.mp4')}; };
          const unknown={...high,width:undefined,height:undefined,quality_desc:'original'};
          const missingEncryption={...low,main_url:'https://unit.fqnovelvod.com/low.mp4',encrypt:undefined};
          return {single:brief({high}),unknown:brief({unknown}),invalid:brief({high,low}),missing:brief({high,low:missingEncryption})};
        })()
        """#)
        let object = try qualityDictionary(result)
        for key in ["single", "invalid", "missing"] {
            let value = try #require(object[key] as? [String: Any])
            #expect(value["width"] as? Int == 1080)
            #expect(value["quality"] as? String == "1080p")
            #expect(value["fallback"] as? Bool == true)
            #expect(value["high"] as? Bool == true)
        }
        let unknown = try #require(object["unknown"] as? [String: Any])
        #expect(unknown["width"] is NSNull)
        #expect(unknown["quality"] as? String == "original")
        #expect(unknown["fallback"] as? Bool == true)
    }
}

private func qualitySource(_ preference: NativePlaybackQuality, label: String = "1080p") -> NativeMediaSource {
    .init(url: URL(string: "https://unit.fqnovelvod.com/video.mp4")!, contentKey: nil,
          userAgent: "Fixture", codec: "h264", quality: label, preference: preference,
          qualityFallback: preference == .dataSaver, width: 1080, height: 1920)
}

private func qualityDictionary(_ value: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
}
