# SwiftTask

[TOC]

## Example code

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