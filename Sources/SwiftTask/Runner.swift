public protocol Runner {
    // metadata can be accessed via owned["metadata"]
    func addTask<T: Task>(_ task: T, metadata: [String: Any]?, options: [String: Any]?)

    func resume()
    func waitUntilQueueIsEmpty()

    var resultHandler: ((GeneralizedTask, StringKeyedSafeDictionary?, Any) -> Void)? { get set }
    var errorHandler: ((GeneralizedTask, StringKeyedSafeDictionary?, Error) -> Void)? { get set }

    var sharedData: StringKeyedSafeDictionary { get set }
}
