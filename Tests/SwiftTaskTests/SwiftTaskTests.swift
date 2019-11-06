import XCTest
@testable import SwiftTask

import NIO
import NIOConcurrencyHelpers
import Foundation

import AsyncHTTPClient
import SwiftSoup

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
            | { (x: String) -> () in throw x }
        var caught: String? = nil
        do {
            try 1 | throwingPipeline
        } catch {
            caught = error as? String
        }
        XCTAssertEqual(caught, "10000")
    }
    
    func createSynchronouslyTestingPipeline(_ total: Int, runner: Runner) -> Pipeline<Int, ()> {
        var pipeline: Pipeline<Int, ()>! = nil
        
        func step(_ i: Int) {
            if i < total {
                runner.addTask(Task(pipeline: pipeline, input: i), metadata: [], options: nil)
            } else {
                XCTAssertEqual(i, total)
                //                XCTAssertTrue(false)
            }
        }
        
        pipeline = buildPipeline(forInputType: Int.self)
            | { $0 + 1 }
            | { print($0); return $0 }
            | step
        return pipeline
    }
    
    let N = 100
    
    func testSingleThreadRunner() {
        
        let runner = SingleThreadRunner(label: "test")
        
        let pipeline = createSynchronouslyTestingPipeline(N, runner: runner)
        
        runner.addTask(Task(pipeline: pipeline, input: 0))
        
        runner.resume()
        runner.waitUntilQueueIsEmpty()
        
    }
    
    func testSimpleNIORunnerForSynchronousTask() {
        
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let runner = SimpleNIORunner(eventLoopGroupProvider: .shared(eventLoopGroup))
        
        let pipeline = createSynchronouslyTestingPipeline(N, runner: runner)
        
        runner.addTask(Task(pipeline: pipeline, input: 0))
        print("first task added")
        runner.resume()
        print("runner resumed")
        runner.waitUntilQueueIsEmpty()
        print("done")
        
    }
    
    func crawl(startURL: URL, allowedDomain: String) {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        
        let runner = SimpleNIORunner(eventLoopGroupProvider: .shared(eventLoopGroup))
        let client = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
        defer { try! client.syncShutdown() }
        
        var visited = Set<String>()
        let visitedLock = RWLock()
        
        func ensureAllowedURL(_ req: HTTPClient.Request) throws -> HTTPClient.Request {
            if req.url.host != allowedDomain {
                throw PipelineShouldBreakError()
            }
            return req
        }
        
        func readByteBufferAllString(_ _buf: ByteBuffer) -> String {
            var buf = _buf
            return buf.readString(length: buf.readableBytes)!
        }
        
        var pipeline: Pipeline<HTTPClient.Request, ()>! = nil
        pipeline = buildPipeline(forInputType: HTTPClient.Request.self)
            | ensureAllowedURL
            | { req in print("visiting: \(req.url.absoluteString)"); return req }
            | Promising { el in { req in client.execute(request: req, eventLoop: .delegate(on: el)).map{ (req, $0) } } }
            | { (req, resp) in (readByteBufferAllString(resp.body!), req.url) }
            | { (body, requestURL) in (try SwiftSoup.parse(body), requestURL) }
            | { (doc, requestURL) in try doc.select("a[href]").array().forEach {
                let realURL = URL(string: try $0.attr("href"), relativeTo: requestURL)!.absoluteString

                do {
                    visitedLock.rLock()
                    defer { visitedLock.rUnlock() }
                    if visited.contains(realURL) {
                        return
                    }
                }
                do {
                    visitedLock.wLock()
                    defer { visitedLock.wUnlock() }
                    visited.insert(realURL)
                }
                runner.addTask(Task(pipeline: pipeline, input: try HTTPClient.Request(url: realURL)))
                }}
        
        runner.errorHandler = { task, metadata, err in
            print("error: \(task): \(err)")
        }
        
        runner.addTask(Task(pipeline: pipeline, input: try! HTTPClient.Request(url: startURL)))
        
        runner.resume()
        runner.waitUntilQueueIsEmpty()
    }
    
    func testBenchmarkCrawling() {
//        crawl(startURL: URL(string: "http://somewhere")!,
//              allowedDomain: "somewhere")
    }
    
    static var allTests = [
        ("testPipeline", testPipeline),
        ("testSingleThreadRunner", testSingleThreadRunner),
        ("testSimpleNIORunnerForSynchronousTask", testSimpleNIORunnerForSynchronousTask),
        
        ("testBenchmarkCrawling", testBenchmarkCrawling),
    ]
}






