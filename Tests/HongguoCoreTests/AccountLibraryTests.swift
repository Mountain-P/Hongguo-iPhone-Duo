// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private let libraryIdentity = AccountLibraryIdentity(device_id: "7000000000000000001", iid: "7000000000000000002", cdid: "00000000-0000-4000-8000-000000000001")
private func librarySession() throws -> AccountSession {
    let device = try AccountAppDevice(deviceID: libraryIdentity.device_id, installID: libraryIdentity.iid, cdid: libraryIdentity.cdid,
        clientUDID: "00000000-0000-4000-8000-000000000002", openUDID: "0011223344556677", createdAtMilliseconds: 1700000000000)
    return try AccountSession(profile: .init(id: "100", nickname: "Fixture"), cookies: [AccountCookie(name: "sessionid", value: "fixture", domain: ".fqnovel.com")], token: "fixture-token", appDevice: device)
}
private func librarySnapshot(_ number: Int = 1) -> AccountLibraryResponse {
    .snapshot(.init(accountID: "100", items: [.init(series: .init(id: String(number), title: "Fixture"))], isComplete: true, pagesRead: 1))
}
private actor LibraryRecorder {
    private(set) var registrations = 0
    private(set) var requests: [AccountLibraryRequest] = []
    var shouldFail = false
    func register() -> AccountLibraryIdentity { registrations += 1; return libraryIdentity }
    func setFailure(_ value: Bool) { shouldFail = value }
    func execute(_ request: AccountLibraryRequest) throws -> AccountLibraryResponse {
        requests.append(request)
        if shouldFail { throw AccountLibraryError(code: "ERR_NETWORK", status: 403) }
        return request.operation == .history || request.operation == .favorites ? librarySnapshot(requests.count) : .acknowledged
    }
}
private actor LibraryGate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    func execute(_ request: AccountLibraryRequest) async -> AccountLibraryResponse {
        calls += 1; let call = calls
        if call == 1 {
            await withCheckedContinuation { continuation in
                blocked = continuation; started = true; waiters.forEach { $0.resume() }; waiters.removeAll()
            }
        }
        return request.operation == .history ? librarySnapshot(call) : .acknowledged
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { waiters.append($0) } } }
    func release() { blocked?.resume(); blocked = nil }
}

struct AccountLibraryTests {
    @Test func historyUsesAccountProfileCookieAndBoundedAdvancingPagination() async throws {
        let raw = try await js(#"""
        const calls=[];
        const value=await library({...base,operation:'history'},{request:async(signed,method,deadline,signal,cookie)=>{
          const u=new URL(signed.url);calls.push({offset:u.searchParams.get('offset'),first:u.searchParams.get('is_first_load'),
            profile:u.searchParams.get('version_name'),origin:u.protocol+'//'+u.hostname,cookie:cookie==='sessionid=fixture',noCookieQuery:!u.searchParams.has('cookie')});
          const first=calls.length===1;
          return {code:0,data:{data_list:[{book_id_str:first?'7690163276214176792':'7690163276214176793',book_name:'Fixture',
            vid:'7690163276214176794',vid_index:2,current_play_position:15250,duration:90000,read_timestamp_ms:1700000000000}],
            has_more:first,next_offset:0}};
        }});
        return {calls,count:value.items.length,complete:value.isComplete,pages:value.pagesRead,
          exact:value.items[0].series.id==='7690163276214176792',position:value.items[0].positionSeconds,duration:value.items[0].durationSeconds};
        """#)
        let value = try dictionary(Data(raw.utf8)), calls = try #require(value["calls"] as? [[String: Any]])
        #expect(calls.count == 2)
        #expect(calls.map { $0["offset"] as? String } == ["0", "500"])
        #expect(calls.map { $0["first"] as? String } == ["true", "false"])
        #expect(calls.allSatisfy { $0["profile"] as? String == "7.3.5.32" && $0["origin"] as? String == "https://api5-normal-lq.fqnovel.com" && $0["cookie"] as? Bool == true && $0["noCookieQuery"] as? Bool == true })
        #expect(value["count"] as? Int == 2 && value["pages"] as? Int == 2)
        #expect(value["complete"] as? Bool == true && value["exact"] as? Bool == true)
        #expect(value["position"] as? Double == 15.25 && value["duration"] as? Double == 90)
    }

    @Test func incompleteListsNeverBecomeAuthoritativeAndRepeatedPagesFail() async throws {
        let raw = try await js(#"""
        let count=0;
        const bounded=await library({...base,operation:'history'},{request:async()=>({code:0,data:{data_list:[{
          book_id_str:String(1000+count++),vid:'9000',read_timestamp_ms:1700000000000}],has_more:true,next_offset:0}})});
        let repeatedCalls=0,repeated='';
        try{await library({...base,operation:'history'},{request:async()=>{repeatedCalls++;return {code:0,data:{data_list:[{
          book_id_str:'1001',vid:'9000',read_timestamp_ms:1700000000000}],has_more:true,next_offset:0}}}})}catch(e){repeated=e.code}
        const favorite=await library({...base,operation:'favorites'},{request:async(signed)=>{
          if(new URL(signed.url).searchParams.get('target_user_id')!=='100')throw new Error('wrong scope');
          return {code:0,data:{video_shelf_info:[{series_id:'200',collect_time:'1700000000'},{series_id:'200'}]}};
        }});
        return {count,boundedComplete:bounded.isComplete,pages:bounded.pagesRead,repeatedCalls,repeated,
          favoriteCount:favorite.items.length,favoriteComplete:favorite.isComplete,collected:favorite.items[0].collectedAtMilliseconds,
          noInventedTitle:favorite.items[0].series.title===''};
        """#)
        let value = try dictionary(Data(raw.utf8))
        #expect(value["count"] as? Int == 10 && value["pages"] as? Int == 10)
        #expect(value["boundedComplete"] as? Bool == false)
        #expect(value["repeatedCalls"] as? Int == 2 && value["repeated"] as? String == "INVALID_CURSOR")
        #expect(value["favoriteCount"] as? Int == 1 && value["favoriteComplete"] as? Bool == false)
        #expect(value["collected"] as? Int64 == 1_700_000_000_000)
        #expect(value["noInventedTitle"] as? Bool == true)
    }

    @Test func favoriteAndProgressBodiesPreserveWireTypesAndExactLargeIdentifiers() async throws {
        let raw = try await js(#"""
        const calls=[],crypto=require('node:crypto');
        const request=async(signed,method,deadline,signal,cookie)=>{
          calls.push({path:new URL(signed.url).pathname,method,body:signed.body.toString(),
            stub:signed.headers['x-ss-stub']===crypto.createHash('md5').update(signed.body).digest('hex').toUpperCase(),
            signedBody:require('app-source').audit.branchOf(signed.url,signed.body,Number(signed.headers['x-khronos']))===2});
          return {code:0};
        };
        await library({...base,operation:'favorite',seriesID:'7690163276214176792',favorite:true},{request});
        await library({...base,operation:'favorite',seriesID:'7690163276214176792',favorite:false},{request});
        const result=await library({...base,operation:'progress',progress:{seriesID:'7690163276214176792',episodeID:'7690163276214176793',
          episodeNumber:8,positionSeconds:15.25,durationSeconds:90,episodeCount:80,watchedAtMilliseconds:1700000000000,seasonIndex:2,isMultiSeason:true}},{request});
        const add=JSON.parse(calls[0].body),remove=JSON.parse(calls[1].body),history=JSON.parse(calls[2].body).update_datas[0],progress=JSON.parse(calls[3].body).books[0];
        return {calls:calls.length,paths:calls.map(x=>x.path),allSigned:calls.every(x=>x.stub&&x.signedBody&&x.method==='POST'),ack:result.acknowledged,
          add:add.update_bookshelf_video_list[0].video_shelf_operate_type,remove:remove.update_bookshelf_video_list[0].video_shelf_operate_type,
          numericExact:calls[2].body.includes('"book_id":7690163276214176792')&&calls[2].body.includes('"vid":7690163276214176793'),
          historyMS:history.current_play_position,durationMS:history.duration,multi:history.is_multi_season,
          bools:history.user_digg===false&&history.is_delete===false&&progress.check_timestamp===false,
          progressMS:progress.current_play_time,stringIDs:progress.book_id==='7690163276214176792'&&progress.item_id==='7690163276214176793'};
        """#)
        let value = try dictionary(Data(raw.utf8))
        #expect(value["calls"] as? Int == 4 && value["ack"] as? Bool == true)
        #expect(value["paths"] as? [String] == ["/reading/bookapi/bookshelf/video/update/v", "/reading/bookapi/bookshelf/video/update/v", "/reading/bookapi/read_history/update/v", "/reading/bookapi/read_progress/upload/v"])
        #expect(value["add"] as? Int == 0 && value["remove"] as? Int == 1)
        #expect(value["historyMS"] as? Int == 15_250 && value["progressMS"] as? Int == 15_250 && value["durationMS"] as? Int == 90_000)
        #expect(value["multi"] as? Int == 1)
        for key in ["allSigned", "numericExact", "bools", "stringIDs"] { #expect(value[key] as? Bool == true) }
    }

    @Test func sourceDenialsAndPartialProgressNeverFallbackRetryOrAcknowledge() async throws {
        let raw = try await js(#"""
        const results=[];
        for(const scenario of ['denied','business','nested','partial']){
          let calls=0;
          const request=async()=>{calls++;if(scenario==='denied'||(scenario==='partial'&&calls===2))throw Object.assign(new Error('private detail'),{status:403});
            return scenario==='business'?{code:123}:scenario==='nested'?{code:0,data:{error_code:123}}:{code:0};};
          const input=scenario==='partial'?{...base,operation:'progress',progress:{seriesID:'200',episodeID:'201',episodeNumber:1,positionSeconds:3,durationSeconds:9,
            episodeCount:3,watchedAtMilliseconds:1700000000000,seasonIndex:0,isMultiSeason:false}}:{...base,operation:'favorite',seriesID:'200',favorite:true};
          try{await library(input,{request});results.push({unexpected:true})}catch(e){results.push({calls,code:e.code||'',status:e.status||0,partial:e.historyAccepted===true})}
        }
        return results;
        """#)
        let values = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        #expect(values.count == 4)
        #expect(values.map { $0["calls"] as? Int } == [1, 1, 1, 2])
        #expect(values[0]["status"] as? Int == 403)
        #expect(values[1]["code"] as? String == "BUSINESS_REJECTED" && values[2]["code"] as? String == "BUSINESS_REJECTED")
        #expect(values[3]["partial"] as? Bool == true && values[3]["status"] as? Int == 403)
    }

    @Test func signerWhitelistInputValidationAndCancellationAreTerminal() async throws {
        let raw = try await js(#"""
        const sign=require('app-source').signedAccountLibraryRequest;
        let blocked=0;
        for(const [method,path,body] of [['GET','/passport/account/info/v2/',null],['POST','/reading/bookapi/read_history/list/v',{}],
          ['GET','/reading/bookapi/bookshelf/video/list/v',{}],['POST','/reading/bookapi/read_progress/upload/v',null]]){
          try{sign(method,path,{},base.identity,body)}catch(e){blocked++}
        }
        let calls=0,invalid='';
        try{await library({...base,operation:'favorite',seriesID:'../1',favorite:true},{request:async()=>{calls++;return {code:0}}})}catch(e){invalid=e.code}
        let timeout='',inFlightAbort=false;
        const realNow=Date.now,frozenNow=realNow();
        // Keep the deadline precheck from expiring during synchronous signing.
        // The native setTimeout clock still aborts the entered request after its 10 ms budget.
        try{
          Date.now=()=>frozenNow;
          try{await library({...base,operation:'history'},{budgetMS:10,request:async(signed,method,deadline,signal)=>new Promise((resolve,reject)=>{
            calls++;const abort=()=>{inFlightAbort=true;reject(signal.reason)};
            if(signal.aborted)abort();else signal.addEventListener('abort',abort,{once:true});})})}catch(e){timeout=e.code}
        }finally{Date.now=realNow}
        return {blocked,invalid,calls,timeout,inFlightAbort};
        """#)
        let value = try dictionary(Data(raw.utf8))
        #expect(value["blocked"] as? Int == 4 && value["invalid"] as? String == "INVALID_INPUT")
        #expect(value["calls"] as? Int == 1 && value["timeout"] as? String == "ETIMEDOUT")
        #expect(value["inFlightAbort"] as? Bool == true)
    }

    @Test func nativeTransportKeepsCookiesOffRegistrationPreservesIDsAndBlocksRedirects() async throws {
        let raw = try await js(#"""
        let phase='register',calls=[];
        globalThis._nativeHTTP=(requestID,json)=>{
          const spec=JSON.parse(json);calls.push({phase,cookie:!!spec.headers.Cookie,token:spec.headers['X-Tt-Token']==='token-only-fixture',host:new URL(spec.url).hostname});
          let response;
          if(phase==='register')response={status:200,headers:{},data:'{"device_id_str":"7000000000000000001","install_id_str":"7000000000000000002"}'};
          else if(phase==='history'||phase==='token')response={status:200,headers:{},data:'{"code":0,"data":{"data_list":[{"book_id":7690163276214176792,"vid":7690163276214176793,"vid_index":2,"read_timestamp_ms":1700000000000}],"has_more":false}}'};
          else response={status:302,headers:{location:'https://novel.snssdk.com/redirect-destination'},data:''};
          __httpDone(requestID,JSON.stringify(response));
        };
        const registration=await require('native-phone-auth').phoneAuth({operation:'register'});const identity={device_id:registration.device.deviceID,iid:registration.device.installID,cdid:registration.device.cdid,openudid:registration.device.openUDID};
        phase='history';const snapshot=await library({...base,identity,operation:'history'});
        phase='token';await library({...base,cookie:'',token:'token-only-fixture',identity,operation:'history'});
        phase='redirect';let blocked='';
        try{await library({...base,identity,operation:'favorites'})}catch(error){blocked=error.code}
        return {registrationCount:calls.filter(x=>x.phase==='register').length,registrationNoCookie:calls.filter(x=>x.phase==='register').every(x=>!x.cookie),
          accountCookie:calls.filter(x=>x.phase==='history'||x.phase==='redirect').every(x=>x.cookie),tokenOnly:calls.some(x=>x.phase==='token'&&x.token&&!x.cookie),redirectCalls:calls.filter(x=>x.phase==='redirect').length,
          accountHost:calls.filter(x=>x.phase!=='register').every(x=>x.host==='api5-normal-lq.fqnovel.com'),blocked,
          exact:snapshot.items[0].series.id==='7690163276214176792'&&snapshot.items[0].episodeID==='7690163276214176793'};
        """#)
        let value = try dictionary(Data(raw.utf8))
        #expect(value["registrationCount"] as? Int == 1)
        #expect(value["redirectCalls"] as? Int == 1 && value["blocked"] as? String == "SECURITY_BLOCKED")
        for key in ["registrationNoCookie", "accountCookie", "accountHost", "exact", "tokenOnly"] { #expect(value[key] as? Bool == true) }
    }

    @Test func sessionIdentityIsReusedAndAcknowledgementsAreIdempotentWithExplicitFailedRetry() async throws {
        let recorder = LibraryRecorder()
        let service = try NativeAccountLibraryService(session: librarySession(), register: { await recorder.register() }, execute: { try await recorder.execute($0) })
        _ = try await service.history(); _ = try await service.history(); _ = try await service.favorites(); _ = try await service.history(fresh: true)
        #expect(await recorder.registrations == 1)
        #expect(await recorder.requests.count == 3)
        #expect(await recorder.requests.allSatisfy { $0.identity == libraryIdentity && $0.accountID == "100" })
        let good = UUID()
        let first = try await service.setFavorite(seriesID: "200", value: true, mutationID: good)
        #expect(try await service.setFavorite(seriesID: "200", value: true, mutationID: good) == first)
        #expect(await recorder.requests.count == 4)
        #expect(await service.resetFailedMutation(good) == false)
        await #expect(throws: AccountLibraryError(code: "MUTATION_CONFLICT")) { try await service.setFavorite(seriesID: "200", value: false, mutationID: good) }
        await recorder.setFailure(true)
        let failed = UUID()
        for _ in 0..<2 {
            await #expect(throws: AccountLibraryError(code: "ERR_NETWORK", status: 403)) { try await service.setFavorite(seriesID: "200", value: false, mutationID: failed) }
        }
        #expect(await recorder.requests.count == 5)
        await recorder.setFailure(false)
        #expect(await service.resetFailedMutation(failed))
        #expect(try await service.setFavorite(seriesID: "200", value: false, mutationID: failed).mutationID == failed)
        #expect(await recorder.requests.count == 6)
        #expect(await recorder.registrations == 1)
    }

    @Test func logoutAndFreshReadPreventLateRepliesFromRestoringOldState() async throws {
        let gate = LibraryGate()
        let service = try NativeAccountLibraryService(session: librarySession(), register: { libraryIdentity }, execute: { await gate.execute($0) })
        let old = Task { try await service.history() }
        await gate.waitUntilStarted()
        #expect(try await service.history(fresh: true).items[0].id == "2")
        await gate.release()
        #expect(try await old.value.items[0].id == "1")
        #expect(try await service.history().items[0].id == "2")
        await service.invalidate()
        await #expect(throws: AccountLibraryError(code: "ACCOUNT_CHANGED")) { try await service.history() }

        let writeGate = LibraryGate()
        let writer = try NativeAccountLibraryService(session: librarySession(), register: { libraryIdentity }, execute: { await writeGate.execute($0) })
        let pending = Task { try await writer.setFavorite(seriesID: "200", value: true, mutationID: UUID()) }
        await writeGate.waitUntilStarted(); await writer.invalidate(); await writeGate.release()
        do { _ = try await pending.value; Issue.record("Logged-out write was acknowledged") }
        catch { #expect(error is CancellationError || (error as? AccountLibraryError)?.code == "ACCOUNT_CHANGED") }
    }

    @Test func parserRejectsFakeAcknowledgementsUnsafeRecordsAndPreservesPartialFailure() throws {
        #expect(throws: AccountLibraryError(code: "INVALID_RESPONSE")) { try AccountLibraryParser.response(#"{"acknowledged":false}"#, operation: .favorite, accountID: "100") }
        #expect(throws: AccountLibraryError(code: "ERR_NETWORK", status: 403, historyAccepted: true)) {
            try AccountLibraryParser.response(#"{"error":"ERR_NETWORK","status":403,"historyAccepted":true}"#, operation: .progress, accountID: "100")
        }
        let bad = #"{"items":[{"series":{"id":"../1","title":"bad","cover":"","description":"","badge":"","tags":[]},"episodeID":"","episodeNumber":0,"positionSeconds":0,"durationSeconds":0}],"isComplete":true,"pagesRead":1}"#
        #expect(throws: AccountLibraryError(code: "INVALID_RESPONSE")) { try AccountLibraryParser.response(bad, operation: .history, accountID: "100") }
    }

    private func js(_ body: String) async throws -> String {
        try await NativeJSRuntime().evaluateForTesting("""
        (async()=>{
          const library=require('account-library').accountLibrary;
          const base={accountID:'100',cookie:'sessionid=fixture',identity:{device_id:'7000000000000000001',iid:'7000000000000000002',cdid:'00000000-0000-4000-8000-000000000001'}};
          \(body)
        })()
        """)
    }
}
