import Foundation
import CoreData

@MainActor enum AskPerformanceTests {
    static func run(model:NSManagedObjectModel,temporaryDirectory:URL) async throws {
        try await transport()
        let trace=AskPipelineTrace(id:UUID())
        await AskPipelineScope.$trace.withValue(trace) {
            await withTaskGroup(of:Void.self) {group in
                for _ in 0..<40 {group.addTask {AskPipelineScope.trace?.record(.collectionRead,milliseconds:1)}}
            }
        }
        precondition(trace.snapshot().samples.count==40 && AskPipelineScope.trace==nil)
        trace.record(.provider,milliseconds:.nan)
        trace.record(.provider,milliseconds:-1)
        precondition(trace.snapshot().samples.count==40)
        for _ in 0..<200 {trace.record(.provider,milliseconds:2,counters:[.inputTokens:25,.requestBytes:-1])}
        precondition(trace.snapshot().samples.count==112)
        trace.record(.taskExit,milliseconds:500);trace.record(.answerAvailable,milliseconds:400)
        precondition(trace.snapshot().samples.count==114 && trace.snapshot().droppedSamples==128)
        let encoded=try JSONEncoder().encode(trace.snapshot())
        let restored=try JSONDecoder().decode(AskPipelineSnapshot.self,from:encoded)
        precondition(restored.traceID==trace.id && restored.samples.count==114 && restored.samples.contains {$0.counters==["inputTokens":25]} && restored.samples.last?.stage == .answerAvailable)
        let server:[String:Any] = ["version":1,"stages":["provider":["milliseconds":4.5,"calls":2],"SECRET_CONTENT":["milliseconds":1,"calls":1]],"counters":["inputTokens":10,"cachedInputTokens":4,"SECRET_CONTENT":"never retained"]]
        let parsed=AskBackendPerformance(try JSONSerialization.jsonObject(with:JSONSerialization.data(withJSONObject:server)))!
        precondition(parsed.samples.count==1 && parsed.samples[0].calls==2 && parsed.samples[0].counters==["inputTokens":10,"cachedInputTokens":4])
        let evidenceTimingRaw:[String:Any] = ["version":1,"stages":["evidence":["milliseconds":0.5,"calls":1]],"counters":["evidenceSourcesSeen":83,"evidenceSourcesRetained":80,"evidenceSourcesOmitted":3,"PRIVATE_URL":"must not be recorded"]]
        let evidenceTiming=AskBackendPerformance(try JSONSerialization.jsonObject(with:JSONSerialization.data(withJSONObject:evidenceTimingRaw)))!
        precondition(evidenceTiming.samples.count==1 && evidenceTiming.samples[0].stage == .evidence && evidenceTiming.samples[0].counters==["evidenceSourcesSeen":83,"evidenceSourcesRetained":80,"evidenceSourcesOmitted":3])
        precondition(AskBackendPerformance(["version":9])==nil)
        let sameTurn=AskPipelineTrace(id:UUID(),turnID:trace.turnID)
        precondition(sameTurn.id != trace.id && sameTurn.turnID==trace.turnID)
        let before=trace.snapshot(),recorder=AskPerformanceRecorder()
        trace.record(.persistence,milliseconds:3);trace.record(.persistence,milliseconds:4)
        let after=trace.snapshot()
        precondition(after.samples.first(where:{$0.stage == .persistence})?.milliseconds==7 && after.samples.first(where:{$0.stage == .persistence})?.calls==2)
        await recorder.recordPipeline(after);await recorder.recordPipeline(before);await recorder.recordPipeline(sameTurn.snapshot())
        let retained=await recorder.pipelineSnapshot()
        precondition(retained.count==2 && retained.first(where:{$0.traceID==trace.id})?.revision==after.revision)
        let other=AskPipelineTrace(id:UUID())
        do {try await AskPipelineScope.$trace.withValue(other) {AskPipelineScope.trace?.record(.retry,milliseconds:1);throw CancellationError()};preconditionFailure()}catch is CancellationError {}
        precondition(AskPipelineScope.trace==nil && other.snapshot().samples.count==1)
        let archive=temporaryDirectory.appendingPathComponent("pipeline.json")
        var writeMS:[Double]=[]
        for _ in 0..<20 {let start=DispatchTime.now().uptimeNanoseconds;precondition(AskPipelineArchive.write([trace.snapshot(),sameTurn.snapshot()],to:archive));writeMS.append(AskPerformanceRecorder.milliseconds(since:start))}
        precondition(!AskPipelineArchive.write([trace.snapshot()],to:temporaryDirectory.appendingPathComponent("absent/subdirectory/file.json")))
        let archived=try JSONDecoder().decode([AskPipelineSnapshot].self,from:Data(contentsOf:archive));precondition(archived.count==2 && archived[0].turnID==archived[1].turnID && archived[0].traceID != archived[1].traceID)
        try JSONSerialization.data(withJSONObject:["kind":"offline diagnostic persistence overhead; not live speed","milliseconds":writeMS],options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/feast-performance-diagnostics-overhead.json"))
        print("PASS bounded content-free timing isolates concurrent requests, validates telemetry, survives cancellation and serialization")

        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        _ = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:temporaryDirectory.appendingPathComponent("performance.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),city=try repo.createFeastList(named:"Copenhagen")
        let place=try repo.createSavedPlace(from:.init(applePlaceID:"timing-fixture",displayNameSnapshot:"Coffee Collective",status:.wantToTry,placeType:.cafe,cuisines:["Coffee"],tags:[],note:nil,websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
        var visible:Set<UUID>=[city.id!],reads=0,fail=false
        let adapter=AskSavedCollection(context:context,visibleCities:{reads+=1;if fail {throw AskError.invalidEvidence};return visible})
        let separate=try adapter.librarySnapshot(),oldIndex=try adapter.index()
        reads=0
        let view=try adapter.readView()
        precondition(reads==1 && view.snapshot.totalCount==separate.totalCount && view.snapshot.places==separate.places)
        precondition(view.index.records==oldIndex.records && view.index.personalCatalog==oldIndex.personalCatalog)
        place.displayNameSnapshot="Unsaved draft"
        let pending=try adapter.readView();precondition(pending.snapshot.places.first!.name=="Coffee Collective")
        place.displayNameSnapshot="Coffee Collective Torvehallerne";try context.save()
        let edited=try adapter.readView();precondition(edited.snapshot.places.first!.name=="Coffee Collective Torvehallerne")
        visible=[]
        let hidden=try adapter.readView();precondition(hidden.snapshot.places.isEmpty)
        visible=[city.id!]
        let visibleAgain=try adapter.readView();precondition(visibleAgain.snapshot.places.count==1)
        fail=true
        do {_ = try adapter.readView();preconditionFailure()}catch {}
        fail=false
        for i in 0..<200 {_ = try repo.createSavedPlace(from:.init(applePlaceID:"timing-\(i)",displayNameSnapshot:"Bounded fixture \(i)",status:.wantToTry,placeType:.restaurant,cuisines:[],tags:[],note:nil,websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))}
        let large=try adapter.readView()
        precondition(large.snapshot.totalCount==201 && large.snapshot.places.count==201 && large.snapshot.complete && large.index.records.count==201 && large.index.catalogComplete)
        let projected=try AskSemanticContext.make(.init(mode:.collection,text:"Count saved places",fromOCR:false),catalog:large.snapshot)
        precondition(projected.index.count<=200 && projected.indexComplete==false)
        print("PASS operation-local read reuse preserves stored values, ordering, permission freshness and errors; full 201-place local catalog has explicitly bounded model context")

        // Offline microbenchmark only. Same complete local store and content;
        // not an estimate of live model/network savings. Both shapes warmed first.
        for _ in 0..<3 {_ = try adapter.librarySnapshot();_ = try adapter.index();_ = try adapter.readView()}
        var separateMS:[Double]=[],combinedMS:[Double]=[]
        for _ in 0..<20 {
            var start=DispatchTime.now().uptimeNanoseconds
            _ = try adapter.librarySnapshot();_ = try adapter.index()
            separateMS.append(AskPerformanceRecorder.milliseconds(since:start))
            start=DispatchTime.now().uptimeNanoseconds;_ = try adapter.readView()
            combinedMS.append(AskPerformanceRecorder.milliseconds(since:start))
        }
        let result:[String:Any] = ["kind":"offline SQLite warm microbenchmark; not live latency","samples":20,"records":201,"separateMilliseconds":separateMS,"combinedMilliseconds":combinedMS]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/tmp/feast-performance-local-benchmark.json"),options:.atomic)
        print("PASS measured equivalent warmed local read shapes; raw offline samples saved separately from live evidence")
    }
}

/// Intercepts every request in this test-only session; no sockets/provider calls.
private final class PerformanceURLProtocol:URLProtocol,@unchecked Sendable {
    private static let lock=NSLock()
    private static var requests:[URLRequest]=[],pending:[PerformanceURLProtocol]=[]
    private static var waiters:[CheckedContinuation<Void,Never>]=[]
    private static var held=false
    static func reset(hold:Bool=false) {lock.withLock {requests=[];pending=[];held=hold}}
    static func seen()->[URLRequest] {lock.withLock {requests}}
    static func waitForRequest()async {
        await withCheckedContinuation {continuation in
            let ready=lock.withLock {if !pending.isEmpty {return true};waiters.append(continuation);return false}
            if ready {continuation.resume()}
        }
    }
    static func release() {
        let values=lock.withLock {let values=pending;pending=[];held=false;return values}
        values.forEach {$0.respond()}
    }
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let (hold,waiting)=Self.lock.withLock {Self.requests.append(request);if Self.held {Self.pending.append(self)};let waiting=Self.waiters;Self.waiters=[];return (Self.held,waiting)}
        waiting.forEach {$0.resume()}
        if !hold {respond()}
    }
    private func respond() {
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json","Set-Cookie":"privateFixture=shouldNotPersist; Secure","Cache-Control":"max-age=3600"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.allowed)
        client?.urlProtocol(self,didLoad:Data("{}".utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension AskPerformanceTests {
    static func transport()async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PerformanceURLProtocol.self]
        let transport=AskHostedHTTP(configuration:config)
        PerformanceURLProtocol.reset()
        var request=URLRequest(url:URL(string:"https://offline.invalid/v1/answer")!);request.httpMethod="POST"
        request.httpBody=Data("{\"mode\":\"conversationStep\",\"requestID\":\"\(UUID())\"}".utf8)
        request.setValue("Bearer first-fixture",forHTTPHeaderField:"Authorization")
        _ = try await transport.send(request)
        request.setValue("Bearer second-fixture",forHTTPHeaderField:"Authorization");_ = try await transport.send(request)
        request.setValue(nil,forHTTPHeaderField:"Authorization");_ = try await transport.send(request)
        let seen=PerformanceURLProtocol.seen()
        precondition(seen.count==3 && seen[0].value(forHTTPHeaderField:"Authorization")=="Bearer first-fixture" && seen[1].value(forHTTPHeaderField:"Authorization")=="Bearer second-fixture" && seen[2].value(forHTTPHeaderField:"Authorization")==nil)
        precondition(seen.allSatisfy {$0.value(forHTTPHeaderField:"Cookie")==nil})
        PerformanceURLProtocol.reset(hold:true)
        let interrupted=Task {let result=try await transport.send(request);try Task.checkCancellation();return result}
        await PerformanceURLProtocol.waitForRequest();interrupted.cancel();PerformanceURLProtocol.release()
        do {_ = try await interrupted.value;preconditionFailure()}catch is CancellationError {}
        precondition(PerformanceURLProtocol.seen().count==1)
        let delegate=AskHostedTransportDelegate(trace:nil),session=URLSession(configuration:config)
        var redirected=true
        delegate.urlSession(session,task:session.dataTask(with:request),willPerformHTTPRedirection:HTTPURLResponse(url:request.url!,statusCode:302,httpVersion:nil,headerFields:nil)!,newRequest:URLRequest(url:URL(string:"https://different.invalid/")!)) {redirected = $0 != nil}
        precondition(!redirected);session.invalidateAndCancel()
        print("PASS reusable ephemeral transport keeps credentials request-local, rejects redirects, disables cookies and settles dispatched Stop without replay")
    }
}
