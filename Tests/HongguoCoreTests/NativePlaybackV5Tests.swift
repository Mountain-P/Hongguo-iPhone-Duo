// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

struct NativePlaybackV5Tests {
    @Test func currentMedusaMatchesIndependentFullWireVector() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Backend/tests/fixtures/signing-v5-playback-312.json")
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        let result = try await NativeJSRuntime().evaluateForTesting("""
        (() => {
          const fixture = \(fixture), crypto = require('node:crypto');
          Date.now = () => 1800000000000;
          crypto.randomBytes = count => count === 18 ? {toString: () => 'synthetic'} : Buffer.from('00000080','hex');
          const a = require('playback-v5').audit, ts = Number(fixture.headers['x-khronos']);
          const query = require('sm3')(Buffer.from(new URL(fixture.url).search.slice(1)));
          const body = crypto.createHash('md5').update(Buffer.from(fixture.body,'base64')).digest();
          const f13 = a.hashF13(query, body, ts);
          return {medusa:a.medusa(query, f13, ts, fixture.identity) === fixture.headers['x-medusa'],
            helios:a.helios(ts) === fixture.headers['x-helios']};
        })()
        """)
        let value = try object(result)
        #expect(value["medusa"] as? Bool == true)
        #expect(value["helios"] as? Bool == true)
    }

    @Test func independentVectorsMatchInsideJavaScriptCore() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/PlaybackV5")
        let f13 = try String(contentsOf: fixtures.appendingPathComponent("signing-v5-f13.json"), encoding: .utf8)
        let carrier = try String(contentsOf: fixtures.appendingPathComponent("signing-v5-carrier.json"), encoding: .utf8)
        let result = try await NativeJSRuntime().evaluateForTesting("""
        (() => {
          const a = require('playback-v5').audit, f13 = \(f13), carrier = \(carrier);
          return {f13: f13.map(row => a.hashF13(Buffer.from(row.query,'hex'), Buffer.from(row.body,'hex'),row.ts)
            .subarray(0,16).toString('hex') === row.digest),
            carrier: carrier.map(row => {
              const source=Buffer.from(row.source,'hex');
              return new a.CarrierV5(Buffer.from(row.key,'hex'),row.ts).encrypt(source,Buffer.from(row.iv,'hex'))
                .toString('hex') === row.encrypted && source.toString('hex') === row.source;
            })};
        })()
        """)
        let value = try object(result)
        #expect(value["f13"] as? [Bool] == Array(repeating: true, count: 32))
        #expect(value["carrier"] as? [Bool] == Array(repeating: true, count: 4))
    }

    @Test func currentProtocolRecoversEmptyPrimaryAndUsesFreshAnonymousIdentity() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (async () => {
          let registrations=0, cachedReads=0, cachedWrites=0, requests=[];
          globalThis._nativeReadPlaybackIdentity=()=>{cachedReads++;return 'null'};
          globalThis._nativeWritePlaybackIdentity=()=>{cachedWrites++};
          globalThis._nativeHTTP=(id,raw)=>{
            const req=JSON.parse(raw), url=new URL(req.url);
            let data;
            if(url.pathname.includes('device_register')) {
              registrations++;
              data={device_id_str:'700000000000000000'+registrations,install_id_str:'800000000000000000'+registrations};
            } else {
              const wire=Buffer.from(req.body,'base64');
              const body=JSON.parse(require('node:zlib').gunzipSync(wire).toString());
              requests.push({host:url.hostname,path:url.pathname,id:url.searchParams.get('device_id'),body,
                version:url.searchParams.get('version_name'), device:url.searchParams.get('device_type'),
                stub:req.headers['x-ss-stub']===require('node:crypto').createHash('md5').update(wire).digest('hex').toUpperCase(),
                v5:!!req.headers['x-medusa']&&!!req.headers['x-helios']&&!req.headers['x-argus']});
              if(requests.length===1) {__httpDone(id,JSON.stringify({status:200,headers:{},data:''}));return}
              const model={video_list:{main:{main_url:'https://unit.fqnovelvod.com/test.mp4',codec_type:'h264',width:1080,height:1920,encrypt:false}}};
              data={data:{'1006':{'200':{video_model:model}}}};
            }
            __httpDone(id,JSON.stringify({status:200,headers:{},data:JSON.stringify(data)}));
          };
          const a=require('app-source');
          const first=await a.fetchAppPlayUrl('200',{contentType:'1006'});
          const second=await a.fetchAppPlayUrl('200',{contentType:'1006'});
          return {registrations,cachedReads,cachedWrites,requests,route:first.recovery.route,
            playable:first.url===second.url&&first.url==='https://unit.fqnovelvod.com/test.mp4'};
        })()
        """#)
        let value = try object(result)
        #expect(value["error"] == nil, "Unexpected runtime result: \(result)")
        #expect(value["registrations"] as? Int == 2)
        #expect(value["cachedReads"] as? Int == 0)
        #expect(value["cachedWrites"] as? Int == 0)
        #expect(value["route"] as? String == "player_v5")
        #expect(value["playable"] as? Bool == true)
        let rows = try #require(value["requests"] as? [[String: Any]])
        #expect(rows.compactMap { $0["host"] as? String } == ["reading.snssdk.com", "api5-normal-sinfonlinea.fqnovel.com", "reading.snssdk.com"])
        #expect(rows.compactMap { $0["id"] as? String } == ["7000000000000000001", "7000000000000000001", "7000000000000000002"])
        for row in rows {
            #expect(row["path"] as? String == "/novel/player/multi_video_model/preload/v1")
            #expect(row["version"] as? String == "7.4.5.32")
            #expect(row["device"] as? String == "25053RT47C")
            #expect(row["stub"] as? Bool == true)
            #expect(row["v5"] as? Bool == true)
            let body = try #require(row["body"] as? [String: Any])
            #expect(body["dr_scene"] as? String == "preload")
            #expect((body["biz_param"] as? [String: Any])?["device_level"] as? Int == 2)
            #expect(body["mixed_video_id_map"] as? [String: [String]] == ["1006": ["200"]])
        }
    }

    @Test(arguments: [401, 403, 429, 200])
    func explicitDenialsNeverTryAlternateHosts(status: Int) async throws {
        let result = try await NativeJSRuntime().evaluateForTesting("""
        (async () => {
          let registrations=0,models=0;
          globalThis._nativeHTTP=(id,raw)=>{
            const req=JSON.parse(raw), registration=new URL(req.url).pathname.includes('device_register');
            registration?registrations++:models++;
            __httpDone(id,JSON.stringify({status:registration?200:\(status),headers:{},data:JSON.stringify(registration?
              {device_id_str:'7000000000000000001',install_id_str:'8000000000000000001'}:{code:110001})}));
          };
          try {await require('app-source').fetchAppPlayUrl('200');return {unexpected:true}}
          catch(e) {return {registrations,models,status:e.status,code:e.code}}
        })()
        """)
        let value = try object(result)
        #expect(value["registrations"] as? Int == 1)
        #expect(value["models"] as? Int == 1)
        if status == 200 { #expect(value["code"] as? String == "BUSINESS_REJECTED") }
        else { #expect(value["status"] as? Int == status) }
    }

    @Test func typedEnvelopeCannotSubstituteAnotherEpisodeOrContentType() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (()=>{
          const normalize=require('playback-recovery').normalizeVideoTabEnvelope;
          const read=value=>{try {normalize('200',value,'1006');return 'accepted'}catch(e){return e.code}};
          return [read({data:{'1006':{'201':{video_model:{}}}}}),
            read({data:{'1004':{'200':{video_model:{}}}}}),
            read({data:{'1006':{'200':{video_model:{}}}}})];
        })()
        """#)
        #expect(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String] == ["MISSING_MODEL", "MISSING_MODEL", "accepted"])
    }

    @Test(arguments: ["success", "wrongVideo", "short", "denied", "unsafe", "stillUnsupported", "lowerQuality", "missingEncryption"])
    func codecNegotiationKeepsIdentityQualityAndEncryptionBoundaries(scenario: String) async throws {
        let result = try await NativeJSRuntime().evaluateForTesting("""
        (async () => {
          const scenario='\(scenario)', requests=[];
          const row={main_url:'https://unit.fqnovelvod.com/video.mp4',codec_type:'bytevc2',width:1920,height:1080,encrypt:false};
          const model={video_id:'video-200',video_duration:60,video_list:{main:row},
            fallback_api:'https://vod.fqnovel.com/model?token=synthetic%2Fbytes%2Bvalue&codec_type=2&codec_type=2'};
          globalThis._nativeHTTP=(id,raw)=>{
            const req=JSON.parse(raw),url=new URL(req.url),codec=url.searchParams.get('codec_type');
            requests.push({codec,token:url.searchParams.get('token'),method:req.method,
              credentials:Object.keys(req.headers).some(k=>['cookie','x-medusa','x-helios','x-tt-token'].includes(k.toLowerCase())),
              duplicates:(url.search.match(/codec_type=/g)||[]).length});
            const item={...row,codec_type:scenario==='stillUnsupported'||(scenario==='success'&&codec==='1')?'bytevc2':'h264'};
            if(scenario==='unsafe') item.main_url='https://untrusted.invalid/video.mp4';
            if(scenario==='lowerQuality') {item.width=1280;item.height=720}
            if(scenario==='missingEncryption') delete item.encrypt;
            const info={video_id:scenario==='wrongVideo'?'another-video':'video-200',
              video_duration:scenario==='short'?30:60,video_list:{main:item}};
            __httpDone(id,JSON.stringify({status:scenario==='denied'?403:200,headers:{},data:JSON.stringify({video_info:{data:info}})}));
          };
          try {
            const source=await require('app-source').audit.consumeAppPlayResponse({data:{'200':{video_model:model}}},
              '200',{playbackQuality:'automatic'},{deadline:Date.now()+5000,route:'player_v5'});
            return {requests,codec:source.codec};
          } catch(e) {return {requests,code:e.code,status:e.status}}
        })()
        """)
        let value = try object(result)
        let requests = try #require(value["requests"] as? [[String: Any]])
        #expect(requests.count == (["success", "stillUnsupported", "lowerQuality"].contains(scenario) ? 2 : 1))
        for request in requests {
            #expect(request["token"] as? String == "synthetic/bytes+value")
            #expect(request["credentials"] as? Bool == false)
            #expect(request["duplicates"] as? Int == 1)
            #expect(request["method"] as? String == "GET")
        }
        switch scenario {
        case "success":
            #expect(value["codec"] as? String == "h264")
            #expect(requests.compactMap { $0["codec"] as? String } == ["1", "3"])
        case "denied": #expect(value["status"] as? Int == 403)
        case "unsafe": #expect(value["code"] as? String == "SECURITY_BLOCKED")
        case "stillUnsupported", "lowerQuality": #expect(value["code"] as? String == "NO_COMPATIBLE_SOURCE")
        default: #expect(value["code"] as? String == "INVALID_RESPONSE")
        }
    }

    private func object(_ raw: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
}
