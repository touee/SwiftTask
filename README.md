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

### a simple crawler

// TBD

### #1

(You can find it [here](./Tests/SwiftTaskTests/SwiftTaskTests.swift#L94))

```swift
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

                if visitedLock.withRLock({
                    visited.contains(realURL)
                }) { return }
                visitedLock.withWLockVoid {
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
```