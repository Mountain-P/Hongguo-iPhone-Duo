// SPDX-License-Identifier: GPL-3.0-only
import Testing
import Foundation
@testable import HongguoCore

struct NativeRuntimeTests {
    @Test func nativeCryptoKnownVectors() throws {
        let key = data("2b7e151628aed2a6abf7158809cf4f3c")
        let plain = data("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        let ctr = try NativeCrypto.cipher(plain, key: key, iv: data("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"), algorithm: "aes-128-ctr", decrypt: false, padding: false)
        #expect(ctr == data("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff"))
        let cbc = try NativeCrypto.cipher(plain, key: key, iv: data("000102030405060708090a0b0c0d0e0f"), algorithm: "aes-128-cbc", decrypt: false, padding: false)
        #expect(cbc == data("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2"))
        #expect(try NativeCrypto.cipher(cbc, key: key, iv: data("000102030405060708090a0b0c0d0e0f"), algorithm: "aes-128-cbc", decrypt: true, padding: false) == plain)
        let payload = Data("匿名註冊 gzip fixture".utf8)
        #expect(try NativeCrypto.gunzip(NativeCrypto.gzip(payload)) == payload)
        #expect(try NativeCrypto.perform("random", ["count": 0]) as? String == "")
        #expect(try NativeCrypto.perform("hash", ["algorithm": "md5", "data": Data("abc".utf8).base64EncodedString()]) as? String == "kAFQmDzST7DWlj99KOF/cg==")
    }

    @Test func javascriptCoreMatchesFixedAuthoritativeSigningVectors() async throws {
        // Synthetic vector facts from Backend/tests/fixtures/signing-vectors.json.
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (() => {
          Math.random = () => 305419896 / 0x100000000;
          const a = require('app-source').audit, ts = 1791290000;
          const query = 'aid=8662&device_id=7000000000000000001&version_name=7.3.5.32&os_version=16&device_type=25053RT47C&device_brand=Redmi&_rticket=1791290000000';
          const body = Buffer.from('test=fixture'), time = Buffer.alloc(4); time.writeUInt32LE(ts);
          return { f13: a.hashF13(a.sm3(query), require('node:crypto').createHash('md5').update(body).digest(), time, ts).toString('hex'),
            helios: a.helios(ts), gorgon: a.xGorgon(query, body, ts, 17767) };
        })()
        """#)
        let object = try dictionary(Data(result.utf8))
        #expect(object["f13"] as? String == "f65fc6c74adc5bd9a5b357c433ba7fbbfc96af21")
        #expect(object["helios"] as? String == "eFY0EuAiWoJZ9zoF6zNu1pS6xaNl2JqeXVHnmakVf60TcY/S")
        #expect(object["gorgon"] as? String == "84046745400140e3038fc2389e409bedaaf351850243fe0a406e")
    }

    @Test func javascriptCoreSignsExactWireBytesAndKeepsProfilesIsolated() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (() => {
          Date.now = () => 1800000000999;
          const a = require('app-source'), crypto = require('node:crypto');
          crypto.randomBytes = count => Buffer.alloc(count, 0x12);
          const body = '{"biz_param":{"device_level":3},"mixed_video_id_map":{"1004":["7000000000000000001"]},"label":"測試 & bytes"}\n';
          const identity = {device_id:'7000000000000000001',iid:'7000000000000000002',cdid:'00000000-0000-4000-8000-000000000001',cookie:'sessionid=DO_NOT_USE',version_name:'9.9.9'};
          const p = a.audit.playbackRequest(body, identity), u = new URL(p.url);
          const expected = require('playback-signature').signPlayer({query:u.search.slice(1),body:p.body,ts:1800000000});
          const changed = require('playback-signature').signPlayer({query:u.search.slice(1),body:Buffer.from(body),ts:1800000000});
          return { exact: p.body.equals(require('node:zlib').gzipSync(Buffer.from(body))),
            stub: p.headers['x-ss-stub'] === crypto.createHash('md5').update(p.body).digest('hex'),
            signed: ['x-argus','x-ladon','x-khronos','x-ss-req-ticket'].every(h=>p.headers[h]===expected[h]),
            wireBound: changed['x-argus'] !== p.headers['x-argus'],
            gzip:p.headers['Content-Encoding'] === 'gzip',
            current:p.headers['passport-sdk-version'] === '5051452' && p.headers['User-Agent'].includes('/74332 '),
            profile:u.searchParams.get('version_name'), noCookie:!u.searchParams.has('cookie') && !p.headers.Cookie,
            search:new URL(a.signedSearchRequest({keyword:'fixture',identity}).url).searchParams.get('version_name') };
        })()
        """#)
        let value = try dictionary(Data(result.utf8))
        for key in ["exact", "stub", "signed", "wireBound", "gzip", "current", "noCookie"] { #expect(value[key] as? Bool == true) }
        #expect(value["profile"] as? String == "7.4.3.32")
        #expect(value["search"] as? String == "7.2.2.32")
    }

    @Test func emptyPrimaryRecoversThroughCompressedAlternatePost() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (async () => {
          let registrations=0, gets=0, posts=0, bodies=[];
          globalThis._nativeHTTP = (id, json) => {
            const request=JSON.parse(json), url=new URL(request.url);
            let data='';
            if(url.pathname.includes('device_register')) {
              registrations++;
              data=JSON.stringify({device_id_str:'7000000000000000001',install_id_str:'7000000000000000002'});
            } else if(request.method==='GET') { gets++; }
            else {
              posts++;
              if(request.headers['Content-Encoding']!=='gzip') throw new Error('Uncompressed recovery request');
              const wire=Buffer.from(request.body,'base64');
              const unzipped=JSON.parse(_nativeInvoke('gunzip',JSON.stringify({data:request.body})));
              bodies.push(JSON.parse(Buffer.from(unzipped.value,'base64').toString('utf8')));
              if(request.headers['x-ss-stub']!==require('node:crypto').createHash('md5').update(wire).digest('hex')) throw new Error('Incorrect wire stub');
              if(url.hostname==='api5-normal-hl.fqnovel.com') {
                data=JSON.stringify({data:{'200':{video_model:{video_list:{main:{main_url:'https://unit.fqnovelvod.com/test.mp4',codec_type:'h264',width:1080,height:1920,encrypt:false}}}}}});
              }
            }
            __httpDone(id,JSON.stringify({status:200,headers:{},data}));
          };
          const source=await require('app-source').fetchAppPlayUrl('200',{contentType:'1004'});
          return {registrations,gets,posts,bodies,route:source.recovery.route,attempts:source.recovery.attempts,
            correct:source.url==='https://unit.fqnovelvod.com/test.mp4',currentUA:source.userAgent.includes('/74332 ')};
        })()
        """#)
        let value = try dictionary(Data(result.utf8))
        #expect(value["registrations"] as? Int == 2)
        #expect(value["gets"] as? Int == 1)
        #expect(value["posts"] as? Int == 2)
        #expect(value["attempts"] as? Int == 2)
        #expect(value["route"] as? String == "registered_post")
        #expect(value["correct"] as? Bool == true)
        #expect(value["currentUA"] as? Bool == true)
        for body in try #require(value["bodies"] as? [[String: Any]]) {
            let ids = try #require(body["mixed_video_id_map"] as? [String: [String]])
            #expect(ids == ["1004": ["200"]])
        }
    }

    @Test func primaryPlaybackRequestUsesTheRegisteredProfileAndRequestedEpisode() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (() => {
          Date.now = () => 1800000000999;
          const identity = {device_id:'7000000000000000001',iid:'7000000000000000002',
            cdid:'00000000-0000-4000-8000-000000000001',cookie:'sessionid=DO_NOT_USE',version_name:'9.9.9'};
          const request = require('app-source').audit.primaryPlaybackRequest('7000000000000000003', identity);
          const url = new URL(request.url);
          return {method:request.method, emptyBody:request.body == null, host:url.hostname,
            episode:url.searchParams.get('video_id'), profile:url.searchParams.get('version_name'),
            signed:['x-argus','x-ladon'].every(name => typeof request.headers[name] === 'string' && request.headers[name].length > 8),
            noCookie:!url.searchParams.has('cookie') && !Object.keys(request.headers).some(name => name.toLowerCase() === 'cookie')};
        })()
        """#)
        let value = try dictionary(Data(result.utf8))
        #expect(value["method"] as? String == "GET")
        #expect(value["host"] as? String == "api5-normal-sinfonlineb.fqnovel.com")
        #expect(value["episode"] as? String == "7000000000000000003")
        #expect(value["profile"] as? String == "7.3.9.32")
        for key in ["emptyBody", "signed", "noCookie"] { #expect(value[key] as? Bool == true) }
    }

    @Test func keyedInlineModelStillRequiresTheRequestedEpisodeAndTrustedMedia() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (async () => {
          const consume = require('app-source').audit.consumeAppPlayResponse;
          const model = url => ({video_list:{main:{main_url:url, codec_type:'h264',
            width:1080, height:1920, encrypt:false}}});
          const envelope = (id, url) => ({data:{[id]:{video_model:JSON.stringify(model(url))}}});
          const accepted = 'https://unit.fqnovelvod.com/test.mp4';
          const parse = response => consume(response, '100', {quality:'auto'}, {deadline:Date.now()+500});
          const outcome = async response => {try {await parse(response);return 'accepted'} catch(error){return error.code}};
          const source = await parse(envelope('100', accepted));
          return {correct:source.url === accepted && source.codec === 'h264',
            wrongEpisode:await outcome(envelope('101', accepted)),
            wrongHost:await outcome(envelope('100', 'https://blocked.invalid/test.mp4'))};
        })()
        """#)
        let value = try dictionary(Data(result.utf8))
        #expect(value["correct"] as? Bool == true)
        #expect(value["wrongEpisode"] as? String == "MISSING_MODEL")
        #expect(value["wrongHost"] as? String == "SECURITY_BLOCKED")
    }

    @Test func registrationEnvelopeDecryptsAndCookiesAreAccountFree() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (async () => {
          const crypto = require('node:crypto'), device = require('playback-device');
          let record;
          const identity = await device.registerPlaybackDevice(async (url, options) => {
            const bytes = options.data, random = bytes.subarray(6,38);
            const salt = Buffer.from('4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58','hex');
            const derived = crypto.createHash('sha512').update(Buffer.concat([crypto.createHash('sha512').update(random).digest(),salt])).digest();
            const decipher = crypto.createDecipheriv('aes-128-cbc',derived.subarray(0,16),derived.subarray(16,32));
            const plaintext = Buffer.concat([decipher.update(bytes.subarray(38)),decipher.final()]), compressed=plaintext.subarray(64);
            const unzipped = JSON.parse(_nativeInvoke('gunzip',JSON.stringify({data:compressed.toString('base64')})));
            record = JSON.parse(Buffer.from(unzipped.value,'base64').toString('utf8'));
            record.hashMatches = crypto.createHash('sha512').update(compressed).digest().equals(plaintext.subarray(0,64));
            record.wireMagic = bytes.subarray(0,6).toString('hex');
            record.stubMatches = options.headers['x-ss-stub'] === crypto.createHash('md5').update(bytes).digest('hex').toUpperCase();
            options.onResponseHeaders({'set-cookie':['install_id=7000000000000000002; Secure','ttreq=anonymous','sessionid=DO_NOT_USE']});
            return {device_id_str:'7000000000000000001',install_id_str:'7000000000000000002'};
          }, {isolated:true,captureCookies:true});
          return {magic:record.magic_tag,wireMagic:record.wireMagic,hashMatches:record.hashMatches,stubMatches:record.stubMatches,
            version:record.header.app_version,identity:identity.device_id,cookie:identity.cookie};
        })()
        """#)
        let value = try dictionary(Data(result.utf8))
        #expect(value["magic"] as? String == "ss_app_log")
        #expect(value["wireMagic"] as? String == "746305100000")
        #expect(value["hashMatches"] as? Bool == true)
        #expect(value["stubMatches"] as? Bool == true)
        #expect(value["version"] as? String == "7.3.9.32")
        #expect(value["identity"] as? String == "7000000000000000001")
        #expect(value["cookie"] as? String == "install_id=7000000000000000002; ttreq=anonymous")
    }

    @Test func nativeHTTPAllowlistAndWireBody() throws {
        for value in ["http://api5-normal-hl.fqnovel.com/", "https://fqnovel.com.attacker.test/", "https://evilfqnovel.com/", "https://user:secret@fqnovel.com/", "https://fqnovel.com:8443/", "file:///etc/passwd", "https://127.0.0.1/"] {
            #expect(!NativeHTTPPolicy.allowed(URL(string: value)!))
            #expect(throws: (any Error).self) { try NativeHTTPPolicy.request(["url": value]) }
        }
        for value in ["https://api5-normal-hl.fqnovel.com/", "https://api5-normal-sinfonlineb.fqnovel.com/", "https://log5-applog-lf.fqnovel.com/", "https://novel.snssdk.com/"] {
            #expect(NativeHTTPPolicy.allowed(URL(string: value)!))
        }
        let bytes = Data("{\"label\":\"測試 & bytes\"}\n".utf8)
        let request = try NativeHTTPPolicy.request(["url": "https://api5-normal-hl.fqnovel.com/", "method": "POST", "body": bytes.base64EncodedString(), "headers": ["Content-Type": "application/json; charset=UTF-8"]])
        #expect(request.httpBody == bytes)
        #expect(!NativeJSRuntime.allowedMediaURL(URL(string: "https://fqnovelvod.com.attacker.test/a.mp4")!))
        #expect(NativeJSRuntime.allowedMediaURL(URL(string: "https://v.example.fqnovelvod.com/a.mp4")!))
    }

    @Test func cancellingAnAwaitedJavaScriptPromiseReturnsCancellation() async throws {
        let task = Task { try await NativeJSRuntime().evaluateForTesting("new Promise(() => {})") }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled runtime unexpectedly succeeded") }
        catch { #expect(error is CancellationError) }
    }

    @Test func completedRuntimeCannotBeReusedAndTimeoutSignalWorks() async throws {
        let runtime = NativeJSRuntime()
        let result = try await runtime.evaluateForTesting(#"new Promise(resolve => { const signal=AbortSignal.timeout(5); signal.addEventListener('abort',()=>resolve(signal.reason.name)); })"#)
        #expect(result == #""TimeoutError""#)
        do { _ = try await runtime.evaluateForTesting("1"); Issue.record("A completed runtime was reused") }
        catch { #expect((error as? NativeSourceError)?.code == "RUNTIME_REUSE") }
    }

    @Test func authorizationStatusSurvivesOversizeOrNonUTF8ErrorBodies() throws {
        for status in [401, 403, 429, 500] {
            let response = HTTPURLResponse(url: URL(string: "https://api5-normal-hl.fqnovel.com/")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": "99999999"])!
            let raw = try NativeHTTP.responseJSON(Data(repeating: 0xff, count: 2 * 1024 * 1024 + 1), response: response)
            let value = try dictionary(Data(raw.utf8))
            #expect(value["status"] as? Int == status)
            #expect(value["data"] as? String == "")
        }
    }

    @Test func playbackCompletionPreservesEmptyResponseAndHTTPDenials() async throws {
        for (status, code, expected) in [(200, "EMPTY_RESPONSE", "EMPTY_RESPONSE"), (403, "BUSINESS_REJECTED", "HTTP_403"),
                                         (429, "ERR_NETWORK", "HTTP_429")] {
            let result = try await NativeJSRuntime().evaluateForTesting("""
                (() => {
                  require('app-source').fetchAppPlayUrl = async () => {
                    throw Object.assign(new Error('fixture'), {status: \(status), code: '\(code)'});
                  };
                  __startResolve('100', '1004');
                  return new Promise(() => {});
                })()
                """)
            let value = try dictionary(Data(result.utf8))
            #expect(value["error"] as? String == expected)
        }
    }

    @Test func javascriptRecoveryHonorsBoundsAndTerminalDenials() async throws {
        let result = try await NativeJSRuntime().evaluateForTesting(#"""
        (async () => {
          const {createPlaybackRecovery,LEGACY_HOSTS}=require('playback-recovery');
          const empty=()=>Object.assign(new Error('empty'),{code:'EMPTY_RESPONSE',status:200});
          let registered=[],hosts=[],identities=[];
          const resolve=createPlaybackRecovery({register:async({scope})=>{const i={id:registered.length};registered.push(scope);return i},
            getModel:async()=>{throw empty()},postModel:async(vid,type,i,host)=>{hosts.push(host);identities.push(i.id);throw empty()},consume:async()=>({})});
          try {await resolve('100')}catch(_){}
          const deniedAttempts=[];
          for (const denial of [{status:401},{status:403},{status:429},
            {code:'DEVICE_REGISTRATION_FAILED',registrationFailure:'HTTP_429'},
            {code:'BUSINESS_REJECTED'}]) {
            let registrations=0, requests=0;
            const rejected=Object.assign(new Error('denied'),denial);
            const denied=createPlaybackRecovery({register:async()=>{registrations++;return{}},
              getModel:async()=>{requests++;throw rejected},postModel:async()=>{requests++},consume:async()=>({})});
            try {await denied('100')}catch(error){deniedAttempts.push({registrations,requests,original:error===rejected})}
          }
          return {registered,hosts,identities,deniedAttempts,expected:LEGACY_HOSTS};
        })()
        """#)
        let value = try dictionary(Data(result.utf8))
        #expect(value["registered"] as? [String] == ["tab", "legacy", "legacy"])
        #expect(value["identities"] as? [Int] == [1, 1, 2, 2])
        let hosts = try #require(value["expected"] as? [String])
        #expect(value["hosts"] as? [String] == hosts + hosts)
        let deniedAttempts = try #require(value["deniedAttempts"] as? [[String: Any]])
        #expect(deniedAttempts.count == 5)
        for denial in deniedAttempts {
            #expect(denial["registrations"] as? Int == 1)
            #expect(denial["requests"] as? Int == 1)
            #expect(denial["original"] as? Bool == true)
        }
    }

    private func data(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
