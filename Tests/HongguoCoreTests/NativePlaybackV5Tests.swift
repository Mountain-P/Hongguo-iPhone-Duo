// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

struct NativePlaybackV5Tests {
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
        #expect(rows.compactMap { $0["host"] as? String } == ["api5-normal-sinfonlineb.fqnovel.com", "api5-normal-sinfonlinea.fqnovel.com", "api5-normal-sinfonlineb.fqnovel.com"])
        #expect(rows.compactMap { $0["id"] as? String } == ["7000000000000000001", "7000000000000000001", "7000000000000000002"])
        for row in rows {
            #expect(row["path"] as? String == "/novel/player/multi_video_model/player/v1")
            #expect(row["stub"] as? Bool == true)
            #expect(row["v5"] as? Bool == true)
            let body = try #require(row["body"] as? [String: Any])
            #expect(body["dr_scene"] as? String == "player")
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

    private func object(_ raw: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
}
