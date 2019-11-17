import XCTest
@testable import SwiftTask

import NIO
import NIOConcurrencyHelpers
import Foundation

import AsyncHTTPClient

extension String: Error {}

final class SwiftTaskTests: XCTestCase {

    func testPipeline() {
        let emptyPipeline = buildPipeline(forInputType: Int.self)
        XCTAssertEqual(try? 42 | emptyPipeline, 42)

        let somePipeline = emptyPipeline
            | abs
            | { $0 * 100 }
        XCTAssertEqual(try? -5 | somePipeline, 500)

        let doubledPipline = somePipeline | somePipeline
        XCTAssertEqual(try? -3 | doubledPipline, 30000)

        let anotherPipeline = doubledPipline
            | { String($0) }
        XCTAssertEqual(try? 2 | anotherPipeline, "20000")

        let throwingPipeline = anotherPipeline
            | { (whatever: String) -> Void in throw whatever }
        var caught: String?
        do {
            try 1 | throwingPipeline
        } catch {
            caught = error as? String
        }
        XCTAssertEqual(caught, "10000")
    }

    func createSynchronouslyTestingPipeline(_ total: Int, runner: Runner) -> Pipeline<Int, ()> {
        var pipeline: Pipeline<Int, ()>! = nil

        func step(_ current: Int) {
            if current < total {
                runner.addTask(PureTask(pipeline: pipeline, input: current), options: nil)
            } else {
                XCTAssertEqual(current, total)
                //                XCTAssertTrue(false)
            }
        }

//        pipeline = buildPipeline(forInputType: Int.self)
//            | { $0 + 1 }
//            | { print($0); return $0 }
//            | step
        pipeline = buildPipeline(forInputType: Int.self)
            |+ { $0 + 1 }
            |+ { print($0); return $0 }
            |+ step
//        pipeline = buildPipeline(forInputType: Int.self)
//            | { let i = $0 + 1; print(i+1); step(i+1); return () }

        return pipeline
    }

    let TOTAL = 10000

    func testSingleThreadRunner() {

        let runner = SingleThreadRunner(label: "test")

        let pipeline = createSynchronouslyTestingPipeline(TOTAL, runner: runner)

        runner.addTask(PureTask(pipeline: pipeline, input: 0))

        runner.resume()
        runner.waitUntilQueueIsEmpty()

    }

    func testSimpleNIORunnerForSynchronousTask() {

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let runner = SimpleNIORunner(eventLoopGroupProvider: .shared(eventLoopGroup))

        let pipeline = createSynchronouslyTestingPipeline(TOTAL, runner: runner)

        runner.addTask(PureTask(pipeline: pipeline, input: 0))
        print("first task added")
        runner.resume()
        print("runner resumed")
        runner.waitUntilQueueIsEmpty()
        print("done")

    }

    enum CrawlTestCondition {
        case syncURLConnection
        case asyncHTTPClientInScope
        case asyncHTTPClientInSharedDict
    }
    func crawl(startURL: URL, allowedDomain: String, condition: CrawlTestCondition) {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount * 2)

        let runner = SimpleNIORunner(eventLoopGroupProvider: .shared(eventLoopGroup))

        var asyncHTTPClient: HTTPClient?
        if [CrawlTestCondition.asyncHTTPClientInScope, CrawlTestCondition.asyncHTTPClientInSharedDict].contains(condition) {
            var clientConfiguration = HTTPClient.Configuration()
            clientConfiguration.timeout.connect = .seconds(10)
            clientConfiguration.timeout.read = .seconds(10)
            let client = HTTPClient(
                eventLoopGroupProvider: .shared(eventLoopGroup),
                configuration: clientConfiguration)
            
            if condition == .asyncHTTPClientInScope {
                asyncHTTPClient = client
            } else {
                runner.sharedData["client"] = client
            }
        }

        var visited = Set<String>()
        let visitedLock = RWLock()

        func ensureAllowedURL(_ req: HTTPClient.Request) throws -> HTTPClient.Request {
            if req.url.host != allowedDomain {
                throw PipelineShouldBreakError()
            }
            return req
        }

        func readByteBufferAllString(_ buf: ByteBuffer?) -> String {
            guard var buf = buf else {
                return ""
            }
            return buf.readString(length: buf.readableBytes)!
        }

        var requestToBodyPipeline: Pipeline<HTTPClient.Request, (String, URL)>!
        switch condition {
        case .syncURLConnection:
            requestToBodyPipeline = buildPipeline(forInputType: HTTPClient.Request.self)
                | Blocking { (req: HTTPClient.Request) throws -> (String, URL) in
                    let url = req.url
                    var resp: URLResponse?
                    let data = try NSURLConnection.sendSynchronousRequest(URLRequest(url: url), returning: &resp)
                    return (String(data: data, encoding: .utf8) ?? "", url) }
        case .asyncHTTPClientInScope:
            requestToBodyPipeline = buildPipeline(forInputType: HTTPClient.Request.self)
                | Promising { el in { req in
                    asyncHTTPClient!.execute(request: req, eventLoop: .delegate(on: el)).map{ (req, $0) } } }
                | { (req, resp) in (readByteBufferAllString(resp.body), req.url) }
        case .asyncHTTPClientInSharedDict:
            requestToBodyPipeline = buildPipeline(forInputType:
                HTTPClient.Request.self)
                | WithData { (shared, owned) in
                    { client in
                        Promising { el in { req in
                            client.execute(request: req, eventLoop: .delegate(on: el)).map{ (req, $0) } } }
                        }(shared["client"] as! HTTPClient) }
                | { (req, resp) in (readByteBufferAllString(resp.body), req.url) }
        }

        var pipeline: Pipeline<HTTPClient.Request, ()>! = nil
        pipeline = buildPipeline(forInputType: HTTPClient.Request.self)
            | ensureAllowedURL
            |+ WithData { shared, owned in
                return {
                    if let referrer = (owned["metadata"] as? [String: Any])?["referrer"] as? URL {
                        print("\(referrer.path) -> \($0.url.path)")
                    }
                    return $0
                }
            }
            | requestToBodyPipeline
            |+ { (body, requestURL) in
                var lastEnd = body.startIndex
                while true {
                    guard let range = body.range(of: #"href="(.*?)""#,
                                                 options: .regularExpression,
                                                 range: lastEnd..<body.endIndex) else {
                        break
                    }
                    lastEnd = range.upperBound
                    let url = String(
                        String(body)[
                            body.index(range.lowerBound, offsetBy: 6)
                            ..< body.index(range.upperBound, offsetBy: -1)])
                    let absoluteURL = URL(string: url, relativeTo: requestURL)!.absoluteString
                    runner.addTask(PureTask(pipeline: pipeline,
                                            input: try HTTPClient.Request(url: absoluteURL),
                                            ownedData: ["metadata":["referrer": requestURL]]))
                }
            }

        runner.errorHandler = { task, metadata, err in
            print("error: \(task): \(err)")
        }

        runner.addTask(PureTask(pipeline: pipeline, input: try! HTTPClient.Request(url: startURL)))

        runner.resume()
        runner.waitUntilQueueIsEmpty()
        
        if condition == .asyncHTTPClientInScope {
            // swiftlint:disable force_try
            try! asyncHTTPClient!.syncShutdown()
        } else if condition == .asyncHTTPClientInSharedDict {
            try! (runner.sharedData["client"] as! HTTPClient).syncShutdown()
        }
        
    }

    func testBenchmarkCrawling() {
      crawl(startURL: URL(string: "http://localhost:1234/bench/start")!,
            allowedDomain: "localhost", condition: .syncURLConnection)
    }

    static var allTests = [
        ("testPipeline", testPipeline),
        ("testSingleThreadRunner", testSingleThreadRunner),
        ("testSimpleNIORunnerForSynchronousTask", testSimpleNIORunnerForSynchronousTask),

        ("testBenchmarkCrawling", testBenchmarkCrawling),
    ]
}
