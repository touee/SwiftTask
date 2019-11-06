
public struct Task<In, Out> {
    public let pipeline: Pipeline<In, Out>
    public let input: In
}

public struct GeneralizedTask {
    public let pipeline: GeneralizedPipeline
    public let input: Any
    
    public var inputType: Any.Type {
        return pipeline.inputType
    }
    public var outputType: Any.Type {
        return pipeline.outputType
    }
    
    public init<In, Out>(from task: Task<In, Out>) {
        self.pipeline = GeneralizedPipeline(from: task.pipeline)
        self.input = task.input
    }
}
