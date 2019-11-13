public protocol Runner {

    func addTask<T: Task>(_ task: T, metadata: Packable?, options: [String: Any]?)

    func resume()
    func waitUntilQueueIsEmpty()

    var resultHandler: ((GeneralizedTask, Packable?, Any) -> Void)? { get set }
    var errorHandler: ((GeneralizedTask, Packable?, Error) -> Void)? { get set }

}
