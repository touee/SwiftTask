
import NIO // using MultiThreadedEventLoopGroup
import Dispatch // using DispatchGroup and DispatchSemaphore
import NIOConcurrencyHelpers // using Lock

public enum EventLoopGroupProvider {
    case shared(EventLoopGroup)
}

public class SimpleNIORunner: Runner {  
    
    class PendingTaskManager {
        
        private let localLoop: EventLoop
        private let runner: SimpleNIORunner
        fileprivate var runningManager: RunningTaskManager!
        
        fileprivate init(on eventLoop: EventLoop, runner: SimpleNIORunner) {
            self.localLoop = eventLoop
            self.runner = runner
        }
        
        private enum PendingManagerStatus {
            case paused
            case waitingBecausePendingQueueIsEmpty
            case waitingBecauseTooManyRunningTasks
            case running
        }
        private var pendingManagerStatus = PendingManagerStatus.paused
        
        private typealias PendingTaskItem = (task: GeneralizedTask, metadata: Packable?)
        private var pendingTaskQueue = SimpleInMemoryQueue(for: PendingTaskItem.self)
        
        private var runningTaskCount = 0
        
        private func local_processPending() {
            
            if self.pendingManagerStatus == .paused {
                return
            }
            
            /// TODO: customizable -ize
            if self.runningTaskCount > System.coreCount {
                self.pendingManagerStatus = .waitingBecauseTooManyRunningTasks
                return
            }
            guard let item = self.pendingTaskQueue.dequeue() else {
                if self.runningTaskCount != 0 {
                    self.pendingManagerStatus = .waitingBecausePendingQueueIsEmpty
                } else {
                    self.pendingManagerStatus = .paused
                    self.runner.reportNoTasksRemain()
                }
                return
            }
            
            self.runningTaskCount += 1
            self.runningManager.executeTask(item.task, item.metadata)
            
            self.localLoop.execute(self.local_processPending)
            self.pendingManagerStatus = .running
            
        }
        
        private func local_resumePendingManager() {
            if self.pendingManagerStatus != .running {
                self.localLoop.execute(self.local_processPending)
                self.pendingManagerStatus = .running
            }
        }
        
        fileprivate func resumePendingManager() {
            self.localLoop.execute(self.local_resumePendingManager)
        }
        
        fileprivate func reportTaskDone() {
            self.localLoop.execute {
                self.runningTaskCount -= 1
                if self.pendingManagerStatus == .waitingBecauseTooManyRunningTasks {
                    self.local_resumePendingManager()
                } else if self.pendingManagerStatus == .waitingBecausePendingQueueIsEmpty
                    && self.runningTaskCount == 0
                    && self.pendingTaskQueue.count == 0 {
                    // let firer reports that there are no more tasks
                    self.local_resumePendingManager()
                }
            }
        }
        
        fileprivate func addTask<In, Out>(_ task: Task<In, Out>, metadata: Packable?, options: [String : Any]?) {
            self.localLoop.execute {
                self.pendingTaskQueue.enqueue(
                    PendingTaskItem(GeneralizedTask(from: task), metadata)
                )
                if self.pendingManagerStatus == .waitingBecausePendingQueueIsEmpty {
                    self.local_resumePendingManager()
                }
            }
        }
        
    }
    
    class RunningTaskManager {
        
        private let localLoop: EventLoop
        private let runner: SimpleNIORunner
        fileprivate weak var pendingManager: PendingTaskManager!
        private let group: EventLoopGroup
        
        fileprivate init(on eventLoop: EventLoop, runner: SimpleNIORunner, controlling group: EventLoopGroup) {
            self.localLoop = eventLoop
            self.runner = runner
            self.group = group
        }
        
        private enum RunningManagerStatus {
            case waitingBecauseRunningQueueIsEmpty
            case running
        }
        private var runningManagerStatus = RunningManagerStatus.waitingBecauseRunningQueueIsEmpty
        
        typealias RunningTaskItem = (task: GeneralizedTask, position: Int, input: Any, metadata: Packable?)
        private var runningTaskQueue = SimpleInMemoryQueue(for: RunningTaskItem.self)
        
        /// TODO: customizable -ize
        private lazy var threadPoolForBlockingIO = NIOThreadPool(numberOfThreads: System.coreCount)
        
        private func local_processRunning() {
            
            guard let item = self.runningTaskQueue.dequeue() else {
                self.runningManagerStatus = .waitingBecauseRunningQueueIsEmpty
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
            case .jointComputing(let fns):
                self.group.next().submit {
                    var out = item.input
                    for fn in fns {
                        out = try fn(out)
                    }
                    return out
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
            
            self.localLoop.execute(self.local_processRunning)
            self.runningManagerStatus = .running

        }
        
        private func local_onTaskDone() {
            self.pendingManager.reportTaskDone()
        }
        
        private func local_enqueueTask(_ task: GeneralizedTask, _ position: Int, _ input: Any, _ metadata: Packable?) {
            self.runningTaskQueue.enqueue(
                RunningTaskItem(task, position, input, metadata))
            if self.runningManagerStatus == .waitingBecauseRunningQueueIsEmpty {
                self.localLoop.execute(self.local_processRunning)
                self.runningManagerStatus = .running
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
    
    private var firer: PendingTaskManager! = nil
    
    private let waitGroup = DispatchGroup()
    
    public init(eventLoopGroupProvider: EventLoopGroupProvider) {
        
        switch eventLoopGroupProvider {
        case .shared(let group):
            self.eventLoopGroup = group
        }
        
        let runnerLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
//        let firerLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        self.firer = PendingTaskManager(on: runnerLoop, runner: self)
//        let schedulerLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        let scheduler = RunningTaskManager(on: runnerLoop, runner: self, controlling: self.eventLoopGroup)
        
        self.firer.runningManager = scheduler
        scheduler.pendingManager = firer
        
        self.waitGroup.enter()
        
    }
    
    public func addTask<In, Out>(_ task: Task<In, Out>, metadata: Packable? = nil, options: [String : Any]? = nil) {
        self.firer.addTask(task, metadata: metadata, options: options)
    }
    
    fileprivate func reportNoTasksRemain() {
        self.waitGroup.leave()
    }
    
    public func resume() {
        self.firer.resumePendingManager()
    }
    
    public func waitUntilQueueIsEmpty() {
        self.waitGroup.wait()
    }
    
}

