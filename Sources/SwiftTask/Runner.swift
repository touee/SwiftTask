public protocol Runner {
    // metadata can be accessed via owned["metadata"]
    func addTask(_ task: GeneralizedTask, metadata: Any?, options: [String: Any]?)

    func resume()
    func waitUntilQueueIsEmpty()

    var resultHandler: ((GeneralizedTask, StringKeyedSafeDictionary?, Any) -> Void)? { get set }
    var errorHandler: ((GeneralizedTask, StringKeyedSafeDictionary?, Error) -> Void)? { get set }

    var sharedData: StringKeyedSafeDictionary { get set }
}

public extension Runner {
    func addTask<T: Task>(_ task: T, metadata: Any? = nil, options: [String: Any]? = nil) {
        self.addTask(GeneralizedTask(from: task), metadata: metadata, options: options)
    }
}
