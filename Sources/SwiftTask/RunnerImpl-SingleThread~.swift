import Dispatch

public class SingleThreadRunner: Runner {

    public var resultHandler: ((GeneralizedTask, Packable?, Any) -> Void)?
    public var errorHandler: ((GeneralizedTask, Packable?, Error) -> Void)?

    typealias QueueItem = (task: GeneralizedTask, metadata: Packable?)
    private var queue = SimpleInMemoryQueue(for: QueueItem.self)

    private var shouldPause = false
    private var isPaused = true
    private let isPausedLock = DispatchSemaphore(value: 1)
    private let dispatcherLock = DispatchSemaphore(value: 0)

    private let group = DispatchGroup()

    public init(label: String) {

        DispatchQueue(label: label, qos: .default).async {
            while true {
                if self.shouldPause {
                    self.group.leave()
                    self.dispatcherLock.wait()
                    self.shouldPause = false
                }
                self.dispatcherLock.wait()
                defer { self.dispatcherLock.signal() }

                guard let item = self.queue.dequeue() else {
                    self.shouldPause = true
                    continue
                }
                self.runTask(item)
            }
        }
    }

    private func runTask(_ item: QueueItem) {
        var out = item.task.input
        for record in item.task.pipeline.filters {
            do {
                switch record.filter {
                case .computing(let filter):
                    out = try filter(out)
                case .blocking(let filter):
                    out = try filter(out)
                default: throw BadRunnerEnvironmentError()
                }
            } catch is PipelineShouldBreakError {
                return
            } catch {
                self.errorHandler?(item.task, item.metadata, error)
                return
            }
        }
        self.resultHandler?(item.task, item.metadata, out)
    }

    public func resume() {
        self.isPausedLock.wait()
        defer { self.isPausedLock.signal() }

        if isPaused {
            self.dispatcherLock.signal()
            self.group.enter()
        }
    }

    public func addTask<T: Task>(_ task: T, metadata: Packable? = nil, options: [String: Any]? = nil) {
        let item: QueueItem = QueueItem(GeneralizedTask(from: task), metadata)
        self.queue.enqueue(item)
    }

    public func waitUntilQueueIsEmpty() {
        self.group.wait()
    }

}
