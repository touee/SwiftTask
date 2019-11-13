import NIO // using MultiThreadedEventLoopGroup
import Dispatch // using DispatchGroup and DispatchSemaphore
import NIOConcurrencyHelpers // using Lock

public enum EventLoopGroupProvider {
    case shared(EventLoopGroup)
}

public class SimpleNIORunner: Runner {

    class TaskManager {

        private let localLoop: EventLoop
        private let runner: SimpleNIORunner
        private let group: EventLoopGroup

        fileprivate init(on eventLoop: EventLoop, runner: SimpleNIORunner, controlling group: EventLoopGroup) {
            self.localLoop = eventLoop
            self.runner = runner
            self.group = group
        }

        //
        // Pending Task Manager
        //

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
            self.local_executeTask(item.task, item.metadata)

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

        private func local_reportTaskDone() {
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

        fileprivate func addTask<T: Task>(_ task: T, metadata: Packable?, options: [String: Any]?) {
            self.localLoop.execute {
                self.pendingTaskQueue.enqueue(
                    PendingTaskItem(GeneralizedTask(from: task), metadata)
                )
                if self.pendingManagerStatus == .waitingBecausePendingQueueIsEmpty {
                    self.local_resumePendingManager()
                }
            }
        }

        //
        // Running Task Manager
        //

        private enum RunningManagerStatus {
            case waitingBecauseRunningQueueIsEmpty
            case running
        }
        private var runningManagerStatus = RunningManagerStatus.waitingBecauseRunningQueueIsEmpty

        typealias RunningTaskItem = (task: GeneralizedTask, position: Int, input: Any, metadata: Packable?)
        private var runningTaskQueue = SimpleInMemoryQueue(for: RunningTaskItem.self)

        /// TODO: customizable -ize
        private lazy var threadPoolForBlockingIO = buildThreadPool()
        private func buildThreadPool() -> NIOThreadPool {
            let pool = NIOThreadPool(numberOfThreads: System.coreCount)
            pool.start()
            return pool
        }

        private func local_processRunning() {

            guard let item = self.runningTaskQueue.dequeue() else {
                self.runningManagerStatus = .waitingBecauseRunningQueueIsEmpty
                return
            }
            
            var deltaPosition = 1

            func onComplete(_ result: Result<Any, Error>) {
                self.localLoop.execute {
                    switch result {
                    case .success(let out):
                        if item.position + deltaPosition == item.task.pipeline.filters.count {
                            self.runner.resultHandler?(item.task, item.metadata, out)
                            self.local_onTaskDone()
                        } else {
                            self.local_enqueueTask(item.task, item.position+deltaPosition, out, item.metadata)
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

            let records = item.task.pipeline.filters
            var record = records[item.position]
            switch record.filterType {
            case .computing:
                self.group.next().submit {
                    var out = try record.filter.execute(input: item.input)
                    while item.position + deltaPosition < records.count {
                        record = records[item.position+deltaPosition]
                        if !record.isJoint {
                            break
                        } else if record.filterType != .computing {
                            break
                        }
                        out = try record.filter.execute(input: out)
                        deltaPosition += 1
                    }
                    return out
                    }.whenComplete(onComplete)
            case .blocking:
                self.threadPoolForBlockingIO.runIfActive(eventLoop: self.group.next()) {
                    try record.filter.execute(input: item.input)
                    }.whenComplete(onComplete)
            case .nio:
                let nextLoop = self.group.next()
                nextLoop.flatSubmit {
                    do {
                        return try record.filter.executePromising(input: item.input, eventLoop: nextLoop)
                    } catch {
                        return nextLoop.makeFailedFuture(error) as EventLoopFuture<Any>
                    }
                    }.whenComplete(onComplete)
            }

            self.localLoop.execute(self.local_processRunning)
            self.runningManagerStatus = .running

        }

        private func local_onTaskDone() {
            self.local_reportTaskDone()
        }

        private func local_enqueueTask(_ task: GeneralizedTask, _ position: Int, _ input: Any, _ metadata: Packable?) {
            self.runningTaskQueue.enqueue(
                RunningTaskItem(task, position, input, metadata))
            if self.runningManagerStatus == .waitingBecauseRunningQueueIsEmpty {
                self.localLoop.execute(self.local_processRunning)
                self.runningManagerStatus = .running
            }
        }

        fileprivate func local_executeTask(_ task: GeneralizedTask, _ metadata: Packable?) {
            self.local_enqueueTask(task, 0, task.input, metadata)
        }

    }

    //
    // Runner
    //
    // swiftlint:disable trailing_whitespace

    public var resultHandler: ((GeneralizedTask, Packable?, Any) -> Void)?
    public var errorHandler: ((GeneralizedTask, Packable?, Error) -> Void)?

    private let eventLoopGroup: EventLoopGroup

    private var manager: TaskManager! = nil

    private let waitGroup = DispatchGroup()

    public init(eventLoopGroupProvider: EventLoopGroupProvider) {

        switch eventLoopGroupProvider {
        case .shared(let group):
            self.eventLoopGroup = group
        }

        let runnerLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
//        let schedulerLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        self.manager = TaskManager(on: runnerLoop, runner: self, controlling: self.eventLoopGroup)

        self.waitGroup.enter()

    }

    public func addTask<T: Task>(_ task: T, metadata: Packable? = nil, options: [String: Any]? = nil) {
        self.manager.addTask(task, metadata: metadata, options: options)
    }

    fileprivate func reportNoTasksRemain() {
        self.waitGroup.leave()
    }

    public func resume() {
        self.manager.resumePendingManager()
    }

    public func waitUntilQueueIsEmpty() {
        self.waitGroup.wait()
    }

}
