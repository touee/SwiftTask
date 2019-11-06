
import NIO // using MultiThreadedEventLoopGroup
import Dispatch // using DispatchGroup and DispatchSemaphore
import NIOConcurrencyHelpers // using Lock

public enum EventLoopGroupProvider {
    case shared(EventLoopGroup)
}

public class SimpleNIORunner: Runner {  
    
    class Firer {
        
        private let localLoop: EventLoop
        private let runner: SimpleNIORunner
        fileprivate var scheduler: Scheduler!
        
        fileprivate init(on eventLoop: EventLoop, runner: SimpleNIORunner) {
            self.localLoop = eventLoop
            self.runner = runner
        }
        
        private enum Status {
            case paused
            case waitingBecauseQueueIsEmpty
            case waitingBecauseSchedulerHasTooManyTasks
            case running
        }
        private var status = Status.paused
        
        private typealias PendingTaskItem = (task: GeneralizedTask, metadata: Packable?)
        private var pendingTaskQueue = SimpleInMemoryQueue(for: PendingTaskItem.self)
        
        private var runningTasks = 0
        
        private func local_process() {
            
            if self.status == .paused {
                return
            }
            
            /// TODO: customizable -ize
            if self.runningTasks > System.coreCount * 20 {
                self.status = .waitingBecauseSchedulerHasTooManyTasks
                return
            }
            guard let item = self.pendingTaskQueue.dequeue() else {
                if self.runningTasks != 0 {
                    self.status = .waitingBecauseQueueIsEmpty
                } else {
                    self.status = .paused
                    self.runner.reportNoTasksRemain()
                }
                return
            }
            
            self.runningTasks += 1
            self.scheduler.executeTask(item.task, item.metadata)
            
            self.localLoop.execute(self.local_process)
            self.status = .running
            
        }
        
        private func local_resume() {
            if self.status != .running {
                self.localLoop.execute(self.local_process)
                self.status = .running
            }
        }
        
        fileprivate func resume() {
            self.localLoop.execute(self.local_resume)
        }
        
        fileprivate func reportTaskDone() {
            self.localLoop.execute {
                self.runningTasks -= 1
                if self.status == .waitingBecauseSchedulerHasTooManyTasks {
                    self.local_resume()
                } else if self.status == .waitingBecauseQueueIsEmpty
                    && self.runningTasks == 0
                    && self.pendingTaskQueue.count == 0 {
                    // let firer reports that there are no more tasks
                    self.local_resume()
                }
            }
        }
        
        fileprivate func addTask<In, Out>(_ task: Task<In, Out>, metadata: Packable?, options: [String : Any]?) {
            self.localLoop.execute {
                self.pendingTaskQueue.enqueue(
                    PendingTaskItem(GeneralizedTask(from: task), metadata)
                )
                if self.status == .waitingBecauseQueueIsEmpty {
                    self.local_resume()
                }
            }
        }
        
    }
    
    class Scheduler {
        
        private let localLoop: EventLoop
        private let runner: SimpleNIORunner
        fileprivate weak var firer: Firer!
        private let group: EventLoopGroup
        
        fileprivate init(on eventLoop: EventLoop, runner: SimpleNIORunner, controlling group: EventLoopGroup) {
            self.localLoop = eventLoop
            self.runner = runner
            self.group = group
        }
        
        private enum Status {
            case waitingBecauseQueueIsEmpty
            case running
        }
        private var status = Status.waitingBecauseQueueIsEmpty
        
        typealias RunningTaskItem = (task: GeneralizedTask, position: Int, input: Any, metadata: Packable?)
        private var runningTaskQueue = SimpleInMemoryQueue(for: RunningTaskItem.self)
        
        /// TODO: customizable -ize
        private let threadPoolForBlockingIO = NIOThreadPool(numberOfThreads: System.coreCount)
        
        private func local_process() {
            
            guard let item = self.runningTaskQueue.dequeue() else {
                self.status = .waitingBecauseQueueIsEmpty
                return
            }
            
            func onComplete(_ result: Result<Any, Error>) {
                self.localLoop.execute {
                    switch result {
                    case .success(let out):
                        if item.position == item.task.pipeline.filters.count - 1 {
                            self.runner.resultHandler?(item.task, item.metadata, out)
                            self.local_onTaskDone()
                        } else {
                            self.local_enqueueTask(item.task, item.position+1, out, item.metadata)
                        }
                    case .failure(let error):
                        if error is PipelineShouldBreakError {
                            // Nop
                        } else {
                            self.runner.errorHandler?(item.task, item.metadata, error)
                        }
                        self.local_onTaskDone()
                    }
                }
            }
            
            let filter = item.task.pipeline.filters[item.position].filter
            switch filter {
            case .computing(let fn):
                self.group.next().submit {
                    try fn(item.input)
                    }.whenComplete(onComplete)
            case .blocking(let fn):
                self.threadPoolForBlockingIO.runIfActive(eventLoop: self.group.next()) {
                    try fn(item.input)
                    }.whenComplete(onComplete)
            case .nio(let fnfn):
                let nextLoop = self.group.next()
                let fn = fnfn(nextLoop)
                nextLoop.flatSubmit{
                    do {
                        return try fn(item.input)
                    } catch {
                        return nextLoop.makeFailedFuture(error) as EventLoopFuture<Any>
                    }
                    }.whenComplete(onComplete)
            }
            
            self.localLoop.execute(self.local_process)
            self.status = .running

        }
        
        private func local_onTaskDone() {
            self.firer.reportTaskDone()
        }
        
        private func local_enqueueTask(_ task: GeneralizedTask, _ position: Int, _ input: Any, _ metadata: Packable?) {
            self.runningTaskQueue.enqueue(
                RunningTaskItem(task, position, input, metadata))
            if self.status == .waitingBecauseQueueIsEmpty {
                self.localLoop.execute(self.local_process)
                self.status = .running
            }
        }
        
        fileprivate func executeTask(_ task: GeneralizedTask, _ metadata: Packable?) {
            self.localLoop.execute {
                self.local_enqueueTask(task, 0, task.input, metadata)
            }
        }
        
    }
    
    public var resultHandler: ((GeneralizedTask, Packable?, Any) -> ())? = nil
    public var errorHandler: ((GeneralizedTask, Packable?, Error) -> ())? = nil
    
    private let eventLoopGroup: EventLoopGroup
    
    private var firer: Firer! = nil
    
    private let waitGroup = DispatchGroup()
    
    public init(eventLoopGroupProvider: EventLoopGroupProvider) {
        
        switch eventLoopGroupProvider {
        case .shared(let group):
            self.eventLoopGroup = group
        }
        
        let firerLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        self.firer = Firer(on: firerLoop, runner: self)
        let schedulerLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        let scheduler = Scheduler(on: schedulerLoop, runner: self, controlling: self.eventLoopGroup)
        
        self.firer.scheduler = scheduler
        scheduler.firer = firer
        
        self.waitGroup.enter()
        
    }
    
    public func addTask<In, Out>(_ task: Task<In, Out>, metadata: Packable? = nil, options: [String : Any]? = nil) {
        self.firer.addTask(task, metadata: metadata, options: options)
    }
    
    fileprivate func reportNoTasksRemain() {
        self.waitGroup.leave()
    }
    
    public func resume() {
        self.firer.resume()
    }
    
    public func waitUntilQueueIsEmpty() {
        self.waitGroup.wait()
    }
    
}

