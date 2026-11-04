import Foundation
private actor PinnedAttempts {
    var values:[String]=[]
    func add(_ value:String){values.append(value)}
    func snapshot()->[String]{values}
}
@MainActor enum AskPinnedWebsiteTests {
    static func run() async throws {
        let text="<html>Public page</html>",body=Data(text.utf8)
        let header="HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\n\r\n"
        let wire=Data(header.utf8)+body
        let complete=try AskPinnedWebsiteClient.response(wire,eof:false);precondition(complete?.body==body)
        let incomplete=try AskPinnedWebsiteClient.response(Data(wire.dropLast()),eof:false);precondition(incomplete==nil)
        let interim=Data("HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n".utf8)+wire
        let hinted=try AskPinnedWebsiteClient.response(interim,eof:false);precondition(hinted?.body==body)
        let chunk=Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n\(String(body.count,radix:16))\r\n\(text)\r\n0\r\n\r\n".utf8)
        let chunked=try AskPinnedWebsiteClient.response(chunk,eof:false);precondition(chunked?.body==body)
        for invalid in [Data(wire.dropLast()),Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx".utf8),Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\nx".utf8),Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\nx".utf8),Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nx".utf8)] {
            do {_ = try AskPinnedWebsiteClient.response(invalid,eof:true);preconditionFailure("Invalid framing accepted")}catch{}
        }
        let tooLarge=Data("HTTP/1.1 200 OK\r\nContent-Length: \(AskPinnedWebsiteClient.maximumBody+1)\r\n\r\n".utf8)
        do {_ = try AskPinnedWebsiteClient.response(tooLarge,eof:false);preconditionFailure("Oversized response accepted")}catch{}
        print("PASS pinned HTTPS HTTP framing, Early Hints, chunking, truncation, conflicting lengths/encoding and strict size limits")
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/PublicBusinessWebsites")
        for (file,name,url,profile) in [("ladbroke-structured.html","The Ladbroke Arms","https://www.ladbrokearms.com/","https://www.instagram.com/ladbrokearms/"),("qima-structured.html","Qima Cafe","https://qimacafe.com/","https://www.instagram.com/qima.cafe/")] {
            let html=try String(contentsOf:root.appendingPathComponent(file),encoding:.utf8),site=URL(string:url)!
            precondition(InstagramWebsiteParser.profile(in:html,restaurantName:name,website:site,savedBusinessWebsite:true)==profile)
            precondition(InstagramWebsiteParser.profile(in:html,restaurantName:name+" Annex",website:site,savedBusinessWebsite:true)==nil)
            precondition(InstagramWebsiteParser.profile(in:html,restaurantName:"Other Business",website:site,savedBusinessWebsite:true)==nil)
            let result=try await AskPinnedWebsiteClient.inspection(website:url,restaurantName:name,resolve:{_ in ["8.8.8.8"]},exchange:{_,ip in
                precondition(ip=="8.8.8.8");return .init(status:200,headers:["content-type":"text/html"],body:Data(html.utf8))
            })
            precondition(result.status == .found && result.profile==profile && result.sourceURL==url)
        }
        let qima=try String(contentsOf:root.appendingPathComponent("qima-structured.html"),encoding:.utf8)
        precondition(InstagramWebsiteParser.profile(in:qima,restaurantName:"Qima Cafe",website:URL(string:"https://qimacafe.com")!)==nil)
        let competing=qima+"<footer><a aria-label=\"Instagram\" href=\"https://www.instagram.com/qimacoffee/\">Brand account</a></footer>"
        precondition(InstagramWebsiteParser.profile(in:competing,restaurantName:"Qima Cafe",website:URL(string:"https://qimacafe.com")!,savedBusinessWebsite:true)==nil)
        precondition(InstagramWebsiteParser.profile(in:qima,restaurantName:"Qima Coffee",website:URL(string:"https://qimacafe.com")!,savedBusinessWebsite:true)==nil)
        precondition(InstagramWebsiteParser.profile(in:qima,restaurantName:"Qima Cafe",website:URL(string:"https://unrelated.org")!,savedBusinessWebsite:true)==nil)
        print("PASS real official JSON-LD/icon-link fixtures retain Ladbroke article alias and Qima Organization identity, reject brand/Annex/host mismatch without a hardcoded answer")
        let unsafe=try await AskPinnedWebsiteClient.inspection(website:"https://fixture.org",restaurantName:"Fixture",resolve:{_ in ["8.8.8.8","127.0.0.1"]},exchange:{_,_ in preconditionFailure("Private mixed DNS must never connect")})
        precondition(unsafe.status == .unsafe)
        let attempts=PinnedAttempts()
        let fallback=try await AskPinnedWebsiteClient.inspection(website:"https://qimacafe.com/",restaurantName:"Qima Cafe",resolve:{_ in ["2606:4700:4700::1111","8.8.8.8"]},exchange:{_,ip in
            await attempts.add(ip)
            if ip=="8.8.8.8" {throw URLError(.cannotConnectToHost)}
            return .init(status:200,headers:["content-type":"text/html"],body:Data(qima.utf8))
        })
        precondition(fallback.status == .found);let tried=await attempts.snapshot();precondition(tried==["8.8.8.8","2606:4700:4700::1111"])
        let foreign=try await AskPinnedWebsiteClient.inspection(website:"https://qimacafe.com",restaurantName:"Qima Cafe",resolve:{_ in ["8.8.8.8"]},exchange:{_,_ in .init(status:302,headers:["location":"https://127.0.0.1/"],body:Data())})
        precondition(foreign.status == .unsafe)
        let task=Task {try await AskPinnedWebsiteClient.inspection(website:"https://qimacafe.com",restaurantName:"Qima Cafe",resolve:{_ in ["8.8.8.8"]},exchange:{_,_ in try await Task.sleep(nanoseconds:5_000_000_000);return .init(status:200,headers:[:],body:Data())})}
        task.cancel();do {_ = try await task.value;preconditionFailure("Cancelled operation completed")}catch is CancellationError{}
        print("PASS pinned-IP contract rejects mixed private DNS/cross-site redirects, bounds fallback to two public addresses and preserves cancellation without provider calls")
    }
}
