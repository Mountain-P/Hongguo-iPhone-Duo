// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

struct NativePhoneRuntimeTests {
    @Test func internationalGorgonMatchesIndependentPackageVectors() async throws {
        let raw = try await NativeJSRuntime().evaluateForTesting(#"""
        (()=>{const f=require('app-source').internationalGorgon;return [
          f('aid=8662&_rticket=1700000000123',Buffer.from('mobile=2e3d3037333437362531303332&mix_mode=1'),1700000000,17767),
          f('aid=8662&device_id=7000000000000000001',null,1700000001,4660),
          f('aid=8662&iid=7000000000000000002',Buffer.from('code=343736313033&mobile=2e3d333334373625313033323d'),1791994999,65535)];})()
        """#)
        #expect(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] == [
            "84046745400107befaaa090287763014e58993aa0d31128cabba", "840434124001cc6c74159676b409faaf9a63085f75ace5d17743",
            "8404ffff4001c2bd97403d84840808fb85d22a58a82f5df7c697"])
    }

    @Test func nativePhoneRequestsUseSameDeviceExactFormsAndRegionSignatureMode() async throws {
        let raw = try await phoneJS(#"""
        const calls=[];const transport=async options=>{
          const u=new URL(options.url),body=options.data.toString(),f=new URLSearchParams(body),h=options.headers;
          const nonce=Buffer.from(h['x-gorgon'],'hex').readUInt16LE(2),ts=Number(h['x-khronos']);
          calls.push({path:u.pathname,host:u.hostname,profile:u.searchParams.get('version_name'),same:u.searchParams.get('device_id')===device.deviceID&&u.searchParams.get('iid')===device.installID&&u.searchParams.get('cdid')===device.cdid,
            full:!!h['x-medusa'],mode4:!h['x-medusa']&&h['x-gorgon']===require('app-source').internationalGorgon(u.search.slice(1),options.data,ts,nonce),
            branch:require('app-source').audit.branchOf(options.url,options.data,ts),
            stub:h['x-ss-stub']===require('node:crypto').createHash('md5').update(options.data).digest('hex').toUpperCase(),
            mobile:f.get('mobile'),code:f.get('code'),type:f.get('type'),mfa:f.get('verify_reason'),method:options.method});
          return {status:200,headers:{'set-cookie':['sessionid=fixture-session','not-approved=discard'],'x-tt-token':'fixture-token'},
            data:'{"message":"success","data":{"user_id":7000000000000000099,"screen_name":"Fixture"}}'};
        };
        await phone({operation:'sendCode',device,phone:'+8613800000000',wirePhone:'+8613800000000'},{transport});
        const result=await phone({operation:'loginSMS',device,phone:'+886912345678',wirePhone:'+886912 3456 78',code:'012345'},{transport});
        await phone({operation:'verifyMFA',device,phone:'+886912345678',mfa:{encryptUID:'fixture',codeKey:'fixture-key',logID:'',scene:'sms_login'}},{transport});
        await phone({operation:'loginSMS',device,phone:'+8860912345678',wirePhone:'+886091 2345 678',code:'012345'},{transport});
        return {calls,exactUID:result.payload.data.user_id==='7000000000000000099',cookie:result.cookies.sessionid==='fixture-session',
          filtered:!Object.hasOwn(result.cookies,'not-approved'),token:result.token==='fixture-token',sameDevice:result.device.deviceID===device.deviceID,
          expectedWire:Buffer.from('+886912 3456 78').map(x=>x^5).toString('hex')};
        """#)
        let value = try dictionary(Data(raw.utf8)), calls = try #require(value["calls"] as? [[String: Any]])
        #expect(calls.map { $0["path"] as? String } == ["/passport/mobile/send_code/v1/", "/passport/mobile/sms_login/", "/passport/upsms/verify/", "/passport/mobile/sms_login/"])
        #expect(calls.allSatisfy { $0["host"] as? String == "api5-normal-lq.fqnovel.com" && $0["profile"] as? String == "7.3.5.32" && $0["same"] as? Bool == true && $0["stub"] as? Bool == true && $0["branch"] as? Int == 2 && $0["method"] as? String == "POST" })
        #expect(calls[0]["full"] as? Bool == true)
        #expect(calls[1]["mode4"] as? Bool == true && calls[2]["mode4"] as? Bool == true && calls[3]["mode4"] as? Bool == true)
        #expect(calls[0]["type"] as? String == "3731")
        #expect(calls[1]["mobile"] as? String == value["expectedWire"] as? String)
        #expect(calls[1]["code"] as? String == "353437363130")
        #expect(calls[2]["mfa"] as? String == "ato")
        for key in ["exactUID", "cookie", "filtered", "token", "sameDevice"] { #expect(value[key] as? Bool == true) }
    }

    @Test func accountRegistrationHasNativeProfileAndKeepsCredentialsOffRegistration() async throws {
        let raw = try await phoneJS(#"""
        let captured;
        globalThis._nativeHTTP=(id,json)=>{
          const spec=JSON.parse(json),bytes=Buffer.from(spec.body,'base64'),crypto=require('node:crypto'),random=bytes.subarray(6,38);
          const salt=Buffer.from('4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58','hex');
          const derived=crypto.createHash('sha512').update(Buffer.concat([crypto.createHash('sha512').update(random).digest(),salt])).digest();
          const decrypt=crypto.createDecipheriv('aes-128-cbc',derived.subarray(0,16),derived.subarray(16,32));
          const plain=Buffer.concat([decrypt.update(bytes.subarray(38)),decrypt.final()]);
          const decoded=JSON.parse(_nativeInvoke('gunzip',JSON.stringify({data:plain.subarray(64).toString('base64')})));
          captured={header:JSON.parse(Buffer.from(decoded.value,'base64').toString()).header,noCookie:!spec.headers.Cookie&&!spec.headers['X-Tt-Token'],ua:spec.headers['User-Agent'].includes('/73532')};
          __httpDone(id,JSON.stringify({status:200,headers:{'set-cookie':['ttreq=anonymous-fixture']},data:'{"device_id_str":"7000000000000000001","install_id_str":"7000000000000000002"}'}));
        };
        const result=await phone({operation:'register'});
        return {version:captured.header.app_version,code:captured.header.version_code,noCookie:captured.noCookie,ua:captured.ua,
          same:result.device.cdid===captured.header.cdid&&result.device.openUDID===captured.header.openudid&&result.device.clientUDID===captured.header.clientudid,
          cookie:result.device.registrationCookies.install_id===result.device.installID};
        """#)
        let value = try dictionary(Data(raw.utf8))
        #expect(value["version"] as? String == "7.3.5.32" && value["code"] as? Int == 73532)
        for key in ["noCookie", "ua", "same", "cookie"] { #expect(value[key] as? Bool == true) }
    }

    @Test func redirectsDenialsAndUnsupportedValidationDoNotRetryOrSendMoreRequests() async throws {
        let raw = try await phoneJS(#"""
        const values=[];
        for(const status of [302,403,429]){
          let count=0;
          try{await phone({operation:'sendCode',device,phone:'+886912345678'},{transport:async()=>{count++;return {status,headers:{'retry-after':'120',location:'https://example.test'},data:''}}})}
          catch(e){values.push({status:e.status,count,retry:e.retryAfter})}
        }
        let unsupported='';try{await phone({operation:'validate'})}catch(e){unsupported=e.code}
        const controller=new AbortController();controller.abort();let cancelled='';
        try{await phone({operation:'sendCode',device,phone:'+886912345678'},{signal:controller.signal,transport:async()=>{throw new Error('must not send')}})}catch(e){cancelled=e.name}
        return {values,unsupported,cancelled};
        """#)
        let value = try dictionary(Data(raw.utf8)), values = try #require(value["values"] as? [[String: Any]])
        #expect(values.map { $0["status"] as? Int } == [302,403,429])
        #expect(values.allSatisfy { $0["count"] as? Int == 1 && $0["retry"] as? Int == 120 })
        #expect(value["unsupported"] as? String == "UNSUPPORTED_VALIDATION" && value["cancelled"] as? String == "AbortError")
    }

    private func phoneJS(_ body: String) async throws -> String {
        try await NativeJSRuntime().evaluateForTesting("""
        (async()=>{const phone=require('native-phone-auth').phoneAuth;
          const device={deviceID:'7000000000000000001',installID:'7000000000000000002',cdid:'00000000-0000-4000-8000-000000000001',
            clientUDID:'00000000-0000-4000-8000-000000000002',openUDID:'0011223344556677',createdAtMilliseconds:1700000000000,registrationCookies:{install_id:'7000000000000000002'}};
          \(body)
        })()
        """)
    }
}
