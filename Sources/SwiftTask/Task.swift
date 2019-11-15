public protocol Task {
    associatedtype In
    associatedtype Out

    var pipeline: Pipeline<In, Out> { get }
    var input: In { get }
    var metadata: Any? { get }
}

public struct PureTask<In, Out>: Task {
    public let pipeline: Pipeline<In, Out>
    public let input: In
    public let metadata: Any?

    public init(pipeline: Pipeline<In, Out>, input: In, metadata: Any? = nil) {
        self.pipeline = pipeline
        self.input = input
        self.metadata = metadata
    }
}

public struct GeneralizedTask {
    public let pipeline: GeneralizedPipeline
    public let input: Any
    public let metadata: Any?

//    public var inputType: Any.Type {
//        return pipeline.inputType
//    }
//    public var outputType: Any.Type {
//        return pipeline.outputType
//    }

    public init<T: Task>(from task: T) {
        self.pipeline = GeneralizedPipeline(from: task.pipeline)
        self.input = task.input
        self.metadata = task.metadata
    }
}
