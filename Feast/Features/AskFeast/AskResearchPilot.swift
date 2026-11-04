import Foundation

/// Operator-only runner controls, with no credentials, app data or network implementation.
struct AskPilotLaunchPlan:Sendable {
    enum Mode:Sendable {case run,status,stop}
    let mode:Mode,runID:String
    static let flags=["-feastRunResearchPilot","-feastResearchPilotStatus","-feastStopResearchPilot"]
    static func requested(_ args:[String])->Bool {args.contains {flags.contains($0)}}
    static func make(_ args:[String],intendedBuild:Bool)throws->Self? {
        guard requested(args),intendedBuild else{return nil}
        guard args.filter({flags.contains($0)}).count==1,args.filter({$0=="-feastResearchPilotRunID"}).count==1,let index=args.firstIndex(of:"-feastResearchPilotRunID"),args.indices.contains(index+1),let id=UUID(uuidString:args[index+1]) else{throw AskHostedError.invalidResponse}
        return .init(mode:args.contains(flags[0]) ? .run : args.contains(flags[1]) ? .status : .stop,runID:id.uuidString.lowercased())
    }
}
actor AskPilotStopOnce {
    private var task:Task<Void,Never>?
    func stop(_ operation:@escaping @Sendable ()async->Void)async {
        if let task {await task.value;return}
        let started=Task.detached {await operation()};task=started;await started.value
    }
}
actor AskPilotSequence {
    private var results:[Data]=[]
    private let stopping=AskPilotStopOnce()
    func snapshot()->[Data] {results}
    func run(consent:@escaping @Sendable ()async->Bool,request:@escaping @Sendable (String,String)async throws->Data,stop:@escaping @Sendable ()async->Void)async throws {
        let stopping=self.stopping
        do {
            try await withTaskCancellationHandler(operation:{
                for (workload,arm) in [("museums","legacy"),("museums","candidate"),("menus","candidate"),("menus","legacy")] {
                    try Task.checkCancellation()
                    guard await consent() else{throw AskHostedError.consentRequired}
                    let result=try await request(workload,arm);results.append(result);try Task.checkCancellation()
                }
            },onCancel:{Task {await stopping.stop(stop)}})
        }catch {await stopping.stop(stop);throw error}
    }
}
