import Dispatch

public class SingleThreadRunner: Runner {

    public var resultHandler: ((GeneralizedTask, StringKeyedSafeDictionary?, Any) -> Void)?
    public var errorHandler: ((GeneralizedTask, StringKeyedSafeDictionary?, Error) -> Void)?

    typealias QueueItem = (task: GeneralizedTask, ownedData: StringKeyedSafeDictionary?)
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
                switch record.filterType {
                case .computing, .blocking:
                    out = try record.filter.execute(input: out,
                                                    sharedData: self.sharedData,
                                                    ownedData: item.ownedData)
                default: throw BadRunnerEnvironmentError()
                }
            } catch is PipelineShouldBreakError {
                return
            } catch {
                self.errorHandler?(item.task, item.ownedData, error)
                return
            }
        }
        self.resultHandler?(item.task, item.ownedData, out)
    }

    public func resume() {
        self.isPausedLock.wait()
        defer { self.isPausedLock.signal() }

        if isPaused {
            self.dispatcherLock.signal()
            self.group.enter()
        }
    }

    public func addTask(_ task: GeneralizedTask, metadata: Any? = nil, options: [String: Any]? = nil) {
        var item: QueueItem!
        if task.pipeline.filters.contains(where: { $0.filter.withExtraData }) {
            let sharedDict = SimpleSafeDictionary()
            item = QueueItem(task, sharedDict)
            if let metadata = metadata {
                sharedDict["metadata"] = metadata
            }
        } else {
            item = QueueItem(task, nil)
        }
        self.queue.enqueue(item)
    }

    public func waitUntilQueueIsEmpty() {
        self.group.wait()
    }
    
    public var sharedData: StringKeyedSafeDictionary = SimpleSafeDictionary()

}
