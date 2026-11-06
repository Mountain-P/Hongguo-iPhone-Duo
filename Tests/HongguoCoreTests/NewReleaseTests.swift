// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private final class NewReleaseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

private actor NewReleaseCounter {
    private(set) var calls = 0
    func next() -> Int { calls += 1; return calls }
}

private actor NewReleaseGate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    func load() async -> DiscoveryPage {
        calls += 1
        let number = calls
        if number == 1 {
            await withCheckedContinuation { continuation in
                blocked = continuation; started = true
                waiters.forEach { $0.resume() }; waiters.removeAll()
            }
        }
        return snapshot(number)
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private func snapshot(_ number: Int) -> DiscoveryPage {
    .init(items: [.init(series: .init(id: String(number), title: "測試片單"))], page: 1, hasMore: false)
}

struct NewReleaseTests {
    @Test func metadataUsesExactSevenDayFiltersStableProfileAndAdvancingCursor() async throws {
        let raw = try await NativeJSRuntime().evaluateForTesting(#"""
        (async () => {
          const requests = [], ids = [];
          const result = await require('new-releases').fetchNewReleases('realDrama', { request: async signed => {
            const body=JSON.parse(signed.body.toString()), url=new URL(signed.url);
            requests.push(body); ids.push(url.searchParams.get('device_id'));
            const first=requests.length===1;
            const rows=Array.from({length:50},(_,i)=>({series_id:'7000000000000000'+String(first?i:i+49).padStart(3,'0'),
              title:'fixture '+i, content_type:1, episode_cnt:10, tag_info:{text:first&&i===0?'今日上新':'新剧'},
              cover:'https://p3-novel.byteimg.com/novel-pic/fixture~abc.heic'}));
            return {code:0,data:{video_data:rows,has_more:true,next_offset:first?50:100,session_id:'fixture-session'}};
          }});
          return {count:result.items.length,calls:requests.length,firstOffset:requests[0].offset,nextOffset:requests[1].offset,
            nextSession:requests[1].session_id,scene:requests[0].req_scene,genre:requests[0].select_items.genre,
            sort:requests[0].select_items.sort,time:requests[0].select_items.online_time,limit:requests[0].limit,
            sameIdentity:!!ids[0]&&ids[0]===ids[1],firstStatus:result.items[0].statusText,
            exactID:result.items[0].id==='7000000000000000000',jpeg:result.items[0].cover.endsWith('~tplv-shrink:640:0.image')};
        })()
        """#)
        let result = try dictionary(Data(raw.utf8))
        #expect(result["count"] as? Int == 99)
        #expect(result["calls"] as? Int == 2)
        #expect(result["firstOffset"] as? Int == 0)
        #expect(result["nextOffset"] as? Int == 50)
        #expect(result["nextSession"] as? String == "fixture-session")
        #expect(result["scene"] as? String == "default")
        #expect(result["genre"] as? [String] == ["short_play"])
        #expect(result["sort"] as? [String] == ["online_time"])
        #expect(result["time"] as? [String] == ["days_7"])
        #expect(result["limit"] as? Int == 50)
        #expect(result["firstStatus"] as? String == "今日上新")
        for key in ["sameIdentity", "exactID", "jpeg"] { #expect(result[key] as? Bool == true) }
    }

    @Test func aiSelectionAndSourceDenialsNeverFallbackOrRetry() async throws {
        let raw = try await NativeJSRuntime().evaluateForTesting(#"""
        (async () => {
          const fetch=require('new-releases').fetchNewReleases;
          let selected;
          await fetch('aiDrama',{request:async signed=>{selected=JSON.parse(signed.body.toString());return {code:0,data:{video_data:[],has_more:false}}}});
          const errors=[];
          for(const scenario of ['http','business','cursor','unsafe-id','wrong-type','oversized']) {
            let calls=0;
            try { await fetch('realDrama',{request:async()=>{
              calls++;
              if(scenario==='http') throw Object.assign(new Error('private detail'),{status:403});
              if(scenario==='business') return {code:123,data:{video_data:[]}};
              if(scenario==='cursor') return {code:0,data:{video_data:[],has_more:true,next_offset:0,session_id:'x'}};
              const row={series_id:scenario==='unsafe-id'?9007199254740992:'100',title:'fixture',content_type:scenario==='wrong-type'?1004:1};
              return {code:0,data:{video_data:scenario==='oversized'?Array(51).fill(row):[row],has_more:false}};
            }}); } catch(error) {errors.push({scenario,calls,code:error.code||'',status:error.status||0});}
          }
          return {scene:selected.req_scene,genre:selected.select_items.genre,errors};
        })()
        """#)
        let result = try dictionary(Data(raw.utf8))
        #expect(result["scene"] as? String == "ai_series")
        #expect(result["genre"] as? [String] == ["ai_series"])
        let errors = try #require(result["errors"] as? [[String: Any]])
        #expect(errors.count == 6)
        #expect(errors.allSatisfy { $0["calls"] as? Int == 1 })
        #expect(errors[0]["status"] as? Int == 403)
        #expect(errors[1]["code"] as? String == "APP_BUSINESS")
        #expect(errors[2]["code"] as? String == "APP_CURSOR")
        #expect(errors.dropFirst(3).allSatisfy { $0["code"] as? String == "APP_SCHEMA" })
    }

    @Test func deadlineAndExternalCancellationStopPendingMetadataRequests() async throws {
        let raw = try await NativeJSRuntime().evaluateForTesting(#"""
        (async()=>{
          const fetch=require('new-releases').fetchNewReleases;
          const request=async(signed,deadline,signal)=>new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(signal.reason)));
          const codes=[];
          try{await fetch('realDrama',{budgetMS:10,request})}catch(error){codes.push(error.code)}
          const controller=new AbortController();setTimeout(()=>controller.abort(),10);
          try{await fetch('aiDrama',{request,signal:controller.signal})}catch(error){codes.push(error.name)}
          return codes;
        })()
        """#)
        #expect(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] == ["ETIMEDOUT", "AbortError"])
        let task = Task { try await NativeJSRuntime().evaluateForTesting(#"require('new-releases').fetchNewReleases('realDrama',{request:async()=>new Promise(()=>{})})"#) }
        try await Task.sleep(for: .milliseconds(20)); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func parserPreservesIdentifiersLimitsSnapshotAndUsesOnlySourceLabels() throws {
        let raw = #"{"items":[{"id":"7000000000000000001","title":" 正確劇名 ","episodeCount":12,"statusText":"今日上新","cover":"https://p3-novel.byteimg.com/novel-pic/a.image"},{"id":"7000000000000000001","title":"重複"},{"id":"101","title":"另一部","statusText":"假造日期","cover":"https://user:secret@p3-novel.byteimg.com/a"},{"id":"../102","title":"無效"}]}"#
        let page = try NativeNewReleaseParser.parse(raw)
        #expect(page.items.map(\.id) == ["7000000000000000001", "101"])
        #expect(page.items[0].series.title == "正確劇名")
        #expect(page.items[0].series.badge == "12 集")
        #expect(page.items[0].statusText == "今日上新")
        #expect(page.items[1].series.cover.isEmpty)
        #expect(page.items[1].statusText.isEmpty)
        #expect(page.page == 1 && !page.hasMore && page.genres.isEmpty)
        #expect(throws: NewReleaseError.malformedResponse) { try NativeNewReleaseParser.parse(#"{"items":[{"id":9007199254740992,"title":"unsafe"}]}"#) }
        let oversized: [String: Any] = ["items": Array(repeating: ["id": "1", "title": "fixture"], count: 101)]
        #expect(throws: NewReleaseError.malformedResponse) { try NativeNewReleaseParser.parse(String(decoding: JSONSerialization.data(withJSONObject: oversized), as: UTF8.self)) }
        #expect(throws: NewReleaseError.httpStatus(403)) { try NativeNewReleaseParser.parse(#"{"error":"ERR_NETWORK","status":403}"#) }
        #expect(throws: NewReleaseError.rejected) { try NativeNewReleaseParser.parse(#"{"error":"APP_BUSINESS"}"#) }
        #expect(throws: NewReleaseError.timeout) { try NativeNewReleaseParser.parse(#"{"error":"ETIMEDOUT"}"#) }
    }

    @Test func cacheHasSixtySecondTTLCategoryIsolationFreshAndClear() async throws {
        let clock = NewReleaseClock(), counter = NewReleaseCounter()
        let service = NativeNewReleaseService(now: { clock.now() }, load: { _ in snapshot(await counter.next()) })
        #expect(try await service.releases(category: .realDrama).items[0].id == "1")
        #expect(try await service.releases(category: .realDrama).items[0].id == "1")
        #expect(try await service.releases(category: .aiDrama).items[0].id == "2")
        #expect(try await service.releases(category: .realDrama, fresh: true).items[0].id == "3")
        clock.advance(60)
        #expect(try await service.releases(category: .realDrama).items[0].id == "4")
        await service.clearCache()
        #expect(try await service.releases(category: .aiDrama).items[0].id == "5")
    }

    @Test func clearingOrFresheningPendingWorkCannotRestoreOldCache() async throws {
        for fresh in [false, true] {
            let gate = NewReleaseGate(), service = NativeNewReleaseService(load: { _ in await gate.load() })
            let old = Task { try await service.releases(category: .realDrama) }
            await gate.waitUntilStarted()
            if fresh { #expect(try await service.releases(category: .realDrama, fresh: true).items[0].id == "2") }
            else { await service.clearCache() }
            await gate.release()
            #expect(try await old.value.items[0].id == "1")
            #expect(try await service.releases(category: .realDrama).items[0].id == "2")
        }
    }

    @Test func cancellationAndFailureNeverPopulateCacheOrReturnPreviousSnapshot() async throws {
        let counter = NewReleaseCounter()
        let service = NativeNewReleaseService(load: { _ in
            let count = await counter.next()
            if count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            if count == 3 { throw NewReleaseError.httpStatus(403) }
            return snapshot(count)
        })
        let cancelled = Task { try await service.releases(category: .realDrama) }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await service.releases(category: .realDrama).items[0].id == "2")
        await #expect(throws: NewReleaseError.httpStatus(403)) { try await service.releases(category: .realDrama, fresh: true) }
        #expect(try await service.releases(category: .realDrama).items[0].id == "4")
    }
}
