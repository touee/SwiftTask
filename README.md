# SwiftTask

SwiftTask provides a simple way to run async codes (tasks). Currently it has implemented a [SwiftNIO](https://github.com/apple/swift-nio) task runner.

[TOC]



## Concepts

### Filter

A filter is a function that convert input to output. The input and output can have different types and count of parameters. Filters are also allowd to throw errors.

Currently, you can define three kinds of filters:

* Computing filters: filters that use cpu effectively;
* Blocking filters: filters that perform blocking tasks;
* NIO filters: filters that return EventLoopFuture. It must be wrapped in a function that takes EventLoop as input. It can only be used in a [runner](#Runner) that uses SwiftNIO.

Example:

```swift
// computing filter:
func parseHTML (_ body: String) throws -> SwiftSoup.Document {
  return try SwiftSoup.parse(body)
}

// blockingfilter:
// (There are definitely better ways)
func readFile (_ url: URL) throws -> String {
  return try String(contentsOfFile: url, encoding: String.Encoding.utf8)
}

// NIO filter:
// (`import AsyncHTTPClient; let client = HTTPClient(…)`)
func executeRequest(_ el: EventLoop) 
	-> ((HTTPClient.Request) throws -> EventLoopFuture<HTTPClient.Response>) {
  return { req in
    client.execute(request: req, eventLoop: el)
  }
}
```



### Pipeline

A pipeline is a composition of filters. its signature is `Pipeline<In, Out>`, where `In` is the input type, and `Out` is the output type.

Usage:

```swift
// (assuming we have `client: HTTPClient`, `lock: Lock`, `fileHandle: FileHandle`)

// create an empty pipeline
// type: Pipeline<Int, Int>
let pipeline1 = buildPipeline(forInputType: Int.self)

// append a computing filter to pipeline
// type: Pipeline<Int, HTTPClient.Request>
let pipeline2 = pipeline1
    | { try HTTPClient.Request(url: URL(string: "https://xkcd.com/\($0)/info.0.json")!) }

// append an NIO filter to pipeline
// type: Pipeline<Int, HTTPClient.Response>
// note that:
//   1. the actual filter is wrapped in a function that takes a EventLoop as input;
//   2. although the actual filter returns a EventLoopFuture, the pipeline's output type is flattened.
let pipeline3 = pipeline2
    | Promising { el in { client.execute(request: $0, eventLoop: .delegate(on: el)) } }

// append a chain of filters
// type: Pipeline<Int, [String: Any]>
let pipeline4 = pipeline3
    | { resp in var buf = resp.body!; return buf.readBytes(length: buf.readableBytes)! }
    | { (body: [UInt8]) -> Data in Data(bytes: body, count: body.count) }
    | { try JSONSerialization.jsonObject(with: $0, options: []) as! [String: Any] }

// append a blocking filter
// type: Pipeline<Int, ()>
let pipeline5 = pipeline4
    | Blocking { respObj in
        lock.withLockVoid {
            fileHandle.write(
                (respObj["safe_title"] as! String + "\n").data(using: .utf8)!)}}

// it is also possible to append other pipelines.
// and also, you throw PipelineShouldBreakError to break a pipeline:
//   if you execute the pipeline directly, you need to distinguish this error from other possible thrown errors on you own;
//   otherwise, if your pipeline is executed inside a runner, throw this error means it would quit without triggering either resultHandler or errorHandler;
// type: Pipeline<Int, ()>
let pipeline6 = buildPipeline(forInputType: Int.self)
    | { if $0 < 1 { throw PipelineShouldBreakError() }; return $0 }
    | pipeline5

// pipeline can be executed directly by the pipe operator (actually, the bitwise OR operator)
// prints: Request(method: … url: https://xkcd.com/42/info.0.json, …)
print(try! 42 | pipeline1)

// prints: SwiftTask.PipelineShouldBreakError
do {
    try -1 | pipeline6
} catch {
    print(error)
}

// prints: SwiftTask.BadRunnerEnvironmentError
// that's because it is not executed inside a runner that uses SwiftNIO, so that the NIO filter appened when creating pipeline3 failed
do {
    try 42 | pipeline6
} catch {
    print(error)
}

// btw, you can refer a pipeline in a filter, that is appended in that exact pipeline, using:
let pipelineX: Pipeline<In, Out>! = nil
pipelineX = buildPipeline(forInputType: In)
    | { print(pipelineX) }
```



### Task

A task is just a pipeline binded with some input value, and sometimes binded with some metadata.

Usage:

```swift
// create a task
let task42 = Task(pipeline: pipeline6, input 42)

// executing task directly has not yet been implemented
```



### Runner

A runner schedules and executes tasks.

We currently have two runner implementation:

* SingleThreadRunner
* SimpleNIORunner

Apparently, if you want to execute NIO tasks, you can only choose `SimpleNIORunner` at present. (Even if you don't have this demand, if you want concurrence, this is still the only reasonable choice.)

Usage: 

``` swift
// (assuming the runner instance is already created as `runner`)

// set result/error handler:
runner.resultHandler = { (task: GeneralizedTask, metadata: Packable?, result: Any) -> () in /* … */ }
runner.errorHandler = { (task: GeneralizedTask, metadata: Packable?, error: Error) -> () in /* … */ }

// add a task
runner.addTask(task42, metadata: nil, options: nil)

// initially, runners are paused, so if you want to resume it:
runner.resume()

// since `resume()` returns instantly, if you want to wait until all task are done (you want), you need to call:
runner.waitUntilQueueIsEmpty()
```



## Example code

### simple [colly](https://github.com/gocolly/colly)-like crawling framework

(still under construction)

```swift

import Foundation

import NIO
import NIOConcurrencyHelpers
import AsyncHTTPClient

import SwiftTask

import SwiftSoup

public struct LimitRule {
    /// Extra randomized duration before a new request
    let randomDelay: TimeInterval
    /// The number of allowed concurrent requests
    let parallelism: Int
}

public class Collector {
    
    private let eventLoopGroup
        = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private lazy var runner
        = SimpleNIORunner(eventLoopGroupProvider: .shared(self.eventLoopGroup))
    private lazy var client
        = HTTPClient(eventLoopGroupProvider: .shared(self.eventLoopGroup))
    
    public var userAgent
        = "SwiftTask Demo Crawler - https://github.com/touee/SwiftTask"
    
    public private(set) var allowedDomains = [String]()
    public private(set) var globalLimitRule: LimitRule? = nil
    private var globalRunningTaskCount = 0
    private var pendingQueue = SimpleInMemoryQueue(for: String.self)
    private var globalTaskLock = Lock()
    
    public typealias HTMLHandler
        = (Collector, Elements, HTTPClient.Request, HTTPClient.Response) throws -> ()
    private var htmlHandlers = [(selector: String, handler: HTMLHandler)]()
    public func onHtml(_ selector: String, _ handler: @escaping HTMLHandler) {
        self.htmlHandlers.append((selector, handler))
    }
    
    public typealias RequestHandler = (HTTPClient.Request) throws -> ()
    private var requestHandlers = [RequestHandler]()
    public func onRequest(_ handler: @escaping RequestHandler) {
        self.requestHandlers.append(handler)
    }
    
    public enum Option {
        case allowedDomains([String])
    }
    
    private func evaluateOptions(_ option: Option) {
        switch option {
        case .allowedDomains(let domains):
            self.allowedDomains += domains
        }
    }
    
    public func limit(_ rule: LimitRule) {
        self.globalTaskLock.withLockVoid {
            self.globalLimitRule = rule
        }
    }
    
    public init(_ options: Option...) {
        for option in options {
            self.evaluateOptions(option)
        }
        // self.runner.errorHandler = self.handleError
        
        self.runner.resultHandler = { (result, metadata, error) in
            self.globalTaskLock.withLockVoid {
                self.globalRunningTaskCount -= 1
                if let rule = self.globalLimitRule, rule.parallelism <= self.globalRunningTaskCount {
                    return
                }
                if let url = self.pendingQueue.dequeue() {
                    self.runner.addTask(
                        Task<String, Void>(pipeline: self.stringURLTaskPipeline!, input: url))
                    self.globalRunningTaskCount += 1
                }
            }
        }
        
    }
    
    private var visitedURLs = Set<String>()
    private var visitedURLsLock = Lock()
    
    // since resume() can be called even if runner is already running, lock is not needed
    private var firstVisit = true
    public func visit(_ url: String) {

        var hasVisited = false
        self.visitedURLsLock.withLockVoid {
            if self.visitedURLs.contains(url) {
                hasVisited = true
            } else {
                self.visitedURLs.insert(url)
            }
        }
        if hasVisited {
            return
        }
        
        self.globalTaskLock.withLockVoid {
            if let rule = self.globalLimitRule,
                self.globalRunningTaskCount >= rule.parallelism {
                self.pendingQueue.enqueue(url)
            } else {
                self.runner.addTask(
                    Task<String, Void>(pipeline: self.stringURLTaskPipeline!, input: url))
                self.globalRunningTaskCount += 1
            }
        }
        
        if firstVisit {
            self.firstVisit = false
            self.runner.resume()
        }
    }
    
    public func wait() {
        self.runner.waitUntilQueueIsEmpty()
    }
    
    private var stringURLTaskPipeline: Pipeline<String, Void>! = nil
    
    public enum CollectorError: Error {
        case invalidURL(rawURL: String)
    }
    
    private func buildPipelines() {
        
        let requestBuildingPipeline = buildPipeline(forInputType: String.self)
            // check url correctness
            | { (rawURL: String) in
                guard let url = URL(string: rawURL) else {
                    throw CollectorError.invalidURL(rawURL: rawURL)
                }
                return url }
            // make request object from url
            | { (url: URL) in try HTTPClient.Request(url: url) }
        
        let requestExecutingPipeline = buildPipeline(forInputType: HTTPClient.Request.self)
            // delay
            | Promising { el in { (req: HTTPClient.Request) in
                guard let rule = self.globalLimitRule else {
                    return el.makeSucceededFuture(req)
                }
                let delay = Double.random(in: 0...1) * rule.randomDelay
                let scheduleTask = el.scheduleTask(in:
                TimeAmount.milliseconds(Int64(delay*1000.0))) { req }
                return scheduleTask.futureResult }}
            // onRequest
            | { (req: HTTPClient.Request) in
                for handler in self.requestHandlers {
                    try handler(req)
                }
                return req }
            // execute the request
            | Promising { el in { (req: HTTPClient.Request) in
                self.client.execute(request: req, eventLoop: .delegate(on: el))
                    .map { resp in (req, resp) } }}
        
        let responseProcessingPipeline = buildPipeline(forInputType: (HTTPClient.Request, HTTPClient.Response).self)
            // parse response body
            | { (req: HTTPClient.Request, resp: HTTPClient.Response) in
                var body = ""
                if var bodyBytes = resp.body {
                    body = bodyBytes.readString(length: bodyBytes.readableBytes) ?? ""
                }
                let doc = try SwiftSoup.parse(body)
                return (req, resp, doc)}
            // process result
            | { (req: HTTPClient.Request, resp: HTTPClient.Response, doc: Document) in
                for handlerItem in self.htmlHandlers {
                    let elems = try doc.select(handlerItem.selector)
                    if elems.isEmpty() {
                        continue
                    }
                    try handlerItem.handler(self, elems, req, resp) } }
        
        self.stringURLTaskPipeline
            = requestBuildingPipeline
            | requestExecutingPipeline
            | responseProcessingPipeline
        
    }
    
}

```



## Ideas

* in chain error handling: `… | filterX |! errorHandler | filterY | …`
  * handlers catch errors in former chain
  * handlers can recover / pass (throw error) / break (throw `PipelineShouldBreakError`) errors
* combining computing filters: `… | filterX |+ filterY |+ filterZ | …`
* middleware filter: `| Middleware { … }`
  * middlewares can share data via a shared dict?

