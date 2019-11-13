import NIO

/// A filter is just a function.
public typealias Filter<In, Out> = (In) throws -> Out
public typealias PromisingFilter<In, Out> = (EventLoop) -> (In) throws -> EventLoopFuture<Out>

public struct Blocking<In, Out> {
    public let filter: Filter<In, Out>
    init(_ filter: @escaping Filter<In, Out>) { self.filter = filter }
}

public struct Promising<In, Out> {
    public let wrappedFilter: PromisingFilter<In, Out>
    public init(_ wrappedFilter: @escaping PromisingFilter<In, Out>) { self.wrappedFilter = wrappedFilter }
}

public struct GeneralizedFilter {
    private let filter: Any
    private let isPromising: Bool
    
    public init<In, Out>(filter: @escaping Filter<In, Out>) {
        self.filter = { (input: Any) -> Any in try filter(input as! In) }
        self.isPromising = false
    }
    public init<In, Out>(filter: Blocking<In, Out>) {
        self.init(filter: filter.filter)
    }
    public init<In, Out>(filter: Promising<In, Out>) {
        self.filter = { (evl: EventLoop) in { (input: Any) -> Any in
            try (filter.wrappedFilter(evl)(input as! In)).map { $0 as Any } } }
        self.isPromising = true
    }
    
    public func execute(input: Any, eventLoop: EventLoop? = nil) throws -> Any {
        var filter = self.filter
        if isPromising {
            filter = (filter as! ((EventLoop) -> (Any) throws -> EventLoopFuture<Any>))(eventLoop!)
        }
        return try (filter as! ((Any) throws -> Any))(input)
    }
    public func executePromising(input: Any, eventLoop: EventLoop) throws -> EventLoopFuture<Any> {
        return try self.execute(input: input, eventLoop: eventLoop) as! EventLoopFuture<Any>
    }
}

/// Record of a filter stored by Pipeline.
public struct FilterRecord {

    public enum FilterType {
        /// filter uses cpu effectively (default).
        /// filter signature: @escaping (T) -> throws U
        /// e.g.: parsing json
        case computing

        /// filter performs blocking I/O operation.
        /// e.g.: write/read files
        /// filter signature: Blocking<@escaping (T) -> throws U>
        case blocking

        /// filter performs NIO operation, and returns a future.
        /// e.g.: using https://github.com/swift-server/async-http-client
        /// filter signature: @escaping (EventLoop) -> ((T) -> throws EventLoopFuture<U>)
        case nio
    }

    /// filter itself
    let filterType: FilterType
    let filter: GeneralizedFilter
//    /// filter's return type
//    let outputType: Any.Type
    let isJoint: Bool
}

/// A Pipeline is a composition of filters.
public final class Pipeline<In, Out> {
    /// composited filters
    public let filters: [FilterRecord]

    /// A nop pipeline for constructing new pipelines.
    fileprivate init() {
        self.filters = []
    }

    private init<X>(from pipeline: Pipeline<In, X>, with filterRecord: FilterRecord, isJoint: Bool = false) {
        self.filters = pipeline.filters + [filterRecord]
    }
    
    /// New pipeline with a computing filter appended
    private convenience init<X>(from pipeline: Pipeline<In, X>, with newFilter: @escaping Filter<X, Out>,
                                isJoint: Bool) {
        self.init(from: pipeline, with: FilterRecord(filterType: .computing, filter: GeneralizedFilter(filter: newFilter), isJoint: isJoint))
    }
    /// New pipeline with a blocking filter appended
    fileprivate convenience init<X>(from pipeline: Pipeline<In, X>, with newFilter: Blocking<X, Out>) {
        self.init(from: pipeline, with: FilterRecord(filterType: .blocking, filter: GeneralizedFilter(filter: newFilter), isJoint: false))
    }
    ///  New pipeline with an NIO filter appended
    private convenience init<X>(from pipeline: Pipeline<In, X>, with newFilter: Promising<X, Out>) {
        self.init(from: pipeline, with: FilterRecord(filterType: .nio, filter: GeneralizedFilter(filter: newFilter), isJoint: false))
    }

    fileprivate init<X>(_ left: Pipeline<In, X>, _ right: Pipeline<X, Out>) {
        self.filters = left.filters + right.filters
    }

    public func callAsFunction(_ input: In, range: Range<Int>? = nil) throws -> Out {
        var out: Any = input
        var filters = ArraySlice(self.filters)
        if let range = range {
            filters = self.filters[range]
        }
        for record in filters {
            switch record.filterType {
            case .computing, .blocking:
                out = try record.filter.execute(input: out)
            case .nio:
                throw BadRunnerEnvironmentError()
            }
        }
        // swiftlint:disable force_cast
        return out as! Out
    }
}

infix operator |+: AdditionPrecedence
extension Pipeline {

    public static func | <X>(lhs: Pipeline<In, X>, rhs: Pipeline<X, Out>) -> Pipeline<In, Out> {
        return Pipeline(lhs, rhs)
    }

    public static func | <X>(lhs: Pipeline<In, X>, rhs: @escaping Filter<X, Out>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: rhs, isJoint: false)
    }
    public static func |+ <X>(lhs: Pipeline<In, X>, rhs: @escaping Filter<X, Out>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: rhs, isJoint: true)
    }
    public static func | <X>(lhs: Pipeline<In, X>, rhs: Blocking<X, Out>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: rhs)
    }
    public static func | <X>(lhs: Pipeline<In, X>, rhs: Promising<X, Out>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: rhs)
    }
}

public func buildPipeline<T>(forInputType inputType: T.Type) -> Pipeline<T, T> {
    return Pipeline<T, T>()
}

public func | <In, Out>(lhr: In, rhs: Pipeline<In, Out>) throws -> Out {
    return try rhs.callAsFunction(lhr)
}

public final class GeneralizedPipeline {
    public let filters: [FilterRecord]
//    public let inputType: Any.Type
//    public var outputType: Any.Type {
//        return self.filters.last?.outputType ?? inputType
//    }

    init<In, Out>(from pipeline: Pipeline<In, Out>) {
//        self.inputType = In.self
        self.filters = pipeline.filters
    }
}
