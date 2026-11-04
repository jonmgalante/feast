import Foundation
private actor PilotProbe {
    var calls=0,stops=0,consents=0
    func consent()->Bool {consents+=1;return consents<2}
    func request(_ workload:String,_ arm:String)throws->Data {calls+=1;return Data("public".utf8)}
    func stop(){stops+=1}
    func counts()->(Int,Int){(calls,stops)}
}
private actor PilotFinalGate {
    var count=0,ready=false
    var starter:CheckedContinuation<Void,Never>?,finisher:CheckedContinuation<Data,Never>?
    func request()async->Data {count+=1;if count<4{return Data("public".utf8)};ready=true;starter?.resume();starter=nil;return await withCheckedContinuation {finisher=$0}}
    func wait()async {if ready{return};await withCheckedContinuation {starter=$0}}
    func release(){finisher?.resume(returning:Data("last public result".utf8));finisher=nil}
}
enum AskResearchPilotTests {
    static func run()async throws {
        let ordinary=try AskPilotLaunchPlan.make(["Feast"],intendedBuild:true);precondition(ordinary==nil)
        let outside=try AskPilotLaunchPlan.make(["Feast","-feastRunResearchPilot"],intendedBuild:false);precondition(outside==nil)
        for args in [["-feastRunResearchPilot"],["-feastRunResearchPilot","-feastStopResearchPilot","-feastResearchPilotRunID",UUID().uuidString]] {do {_ = try AskPilotLaunchPlan.make(args,intendedBuild:true);preconditionFailure()}catch {}}
        let probe=PilotProbe(),sequence=AskPilotSequence()
        do {try await sequence.run(consent:{await probe.consent()},request:{try await probe.request($0,$1)},stop:{await probe.stop()});preconditionFailure()}catch AskHostedError.consentRequired {}
        let counts=await probe.counts(),partial=await sequence.snapshot();precondition(counts.0==1 && counts.1==1 && partial==[Data("public".utf8)])
        let once=AskPilotStopOnce(),other=PilotProbe()
        await withTaskGroup(of:Void.self){group in for _ in 0..<10 {group.addTask {await once.stop {await other.stop()}}}}
        let stopped=await other.counts();precondition(stopped.1==1)
        let cancellation=AskPilotSequence(),cancelProbe=PilotProbe()
        let task=Task {try await cancellation.run(consent:{true},request:{_,_ in try await Task.sleep(nanoseconds:5_000_000_000);return Data()},stop:{await cancelProbe.stop()})}
        task.cancel();do{try await task.value;preconditionFailure()}catch is CancellationError {}
        let cancelled=await cancelProbe.counts();precondition(cancelled.1==1)
        let finalGate=PilotFinalGate(),finalSequence=AskPilotSequence(),finalProbe=PilotProbe()
        let lastTask=Task {try await finalSequence.run(consent:{true},request:{_,_ in await finalGate.request()},stop:{await finalProbe.stop()})}
        await finalGate.wait();lastTask.cancel();await finalGate.release()
        do{try await lastTask.value;preconditionFailure("Cancelled final result was reported completed")}catch is CancellationError {}
        let finalPartial=await finalSequence.snapshot(),finalCounts=await finalProbe.counts();precondition(finalPartial.count==4 && finalCounts.1==1)
        let failed=AskPilotSequence(),failureProbe=PilotProbe()
        do {try await failed.run(consent:{true},request:{_,_ in throw URLError(.timedOut)},stop:{await failureProbe.stop()});preconditionFailure()}catch is URLError {}
        let failureCounts=await failureProbe.counts();precondition(failureCounts.1==1)
        print("PASS operator pilot ignores icon launch/invalid flags, rechecks consent, keeps partial results and sends cancellation Stop once; no network")
    }
}
