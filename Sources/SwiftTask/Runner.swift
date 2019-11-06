
protocol Runner {
    
    func addTask<In, Out>(_ task: Task<In, Out>, metadata: Packable?, options: [String: Any]?)
    
    func resume()
    func waitUntilQueueIsEmpty()
    
    var resultHandler: ((GeneralizedTask, Packable?, Any) -> ())? { get set }
    var errorHandler: ((GeneralizedTask, Packable?, Error) -> ())? { get set }
    
}
