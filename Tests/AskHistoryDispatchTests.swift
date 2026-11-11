import Foundation

private actor HistoryDispatchCounter {
    var count=0
    func hit(){count+=1}
    func value()->Int {count}
}
private enum HistoryDispatchDenied:Error {case denied}

@MainActor enum AskHistoryDispatchTests {
    static func run()async throws {
        let counter=HistoryDispatchCounter()
        var provider=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://synthetic-repro.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"A",count:43)},approve:{_,_ in true},send:{request in
            await counter.hit()
            return (Data(),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        provider.revalidatesHistoryAccess=true
        let checkedProvider=provider
        for operation in ["status","cancel","ack","submit","unknown","missing","malformed","no-body"] {
            var request=URLRequest(url:provider.configuration.endpoint)
            if operation=="malformed" {request.httpBody=Data("{".utf8)}
            else if operation != "no-body" {request.httpBody=try JSONSerialization.data(withJSONObject:operation=="missing" ? [:] : ["op":operation])}
            let before=await counter.value()
            var blocked=false
            do {_ = try await AskHistoryAccessScope.$revalidate.withValue({throw HistoryDispatchDenied.denied}) {try await checkedProvider.sendWithHistoryAccessCheck(request)}}
            catch HistoryDispatchDenied.denied {blocked=true}
            let exempt=["status","cancel","ack"].contains(operation),after=await counter.value()
            precondition(blocked == !exempt && after-before == (exempt ? 1 : 0),"Dispatch fence mismatch for \(operation)")
            print("PASS actual hosted dispatch history fence: \(operation)")
        }
        let request=URLRequest(url:provider.configuration.endpoint)
        _ = try await checkedProvider.sendWithHistoryAccessCheck(request)
        provider.revalidatesHistoryAccess=false
        let uncheckedProvider=provider
        _ = try await AskHistoryAccessScope.$revalidate.withValue({throw HistoryDispatchDenied.denied}) {try await uncheckedProvider.sendWithHistoryAccessCheck(request)}
        let total=await counter.value();precondition(total==5)
        print("PASS actual hosted dispatch: nil scope and disabled flag preserve ordinary transport")
    }
}
