import NIO

/// A filter is just a function.
public typealias Filter<In, Out> = (In) throws -> Out
public typealias PromisingFilter<In, Out> = (EventLoop) -> (In) throws -> EventLoopFuture<Out>
public typealias GeneralizedFilter = (Any) throws -> Any
public typealias GeneralizedPromisingFilter = (EventLoop) -> (Any) throws -> EventLoopFuture<Any>

public struct Blocking<In, Out> {
    public let filter: Filter<In, Out>
    init(_ filter: @escaping Filter<In, Out>) { self.filter = filter }
}

public struct Promising<In, Out> {
    public let wrappedFilter: PromisingFilter<In, Out>
    public init(_ wrappedFilter: @escaping PromisingFilter<In, Out>) { self.wrappedFilter = wrappedFilter }
}

/// Record of a filter stored by Pipeline.
public struct FilterRecord {

    public enum Filter {
        /// filter uses cpu effectively (default).
        /// filter signature: @escaping (T) -> throws U
        /// e.g.: parsing json
        case computing(GeneralizedFilter)

        /// filter performs blocking I/O operation.
        /// e.g.: write/read files
        /// filter signature: Blocking<@escaping (T) -> throws U>
        case blocking(GeneralizedFilter)

        /// filter performs NIO operation, and returns a future.
        /// e.g.: using https://github.com/swift-server/async-http-client
        /// filter signature: @escaping (EventLoop) -> ((T) -> throws EventLoopFuture<U>)
        case nio(GeneralizedPromisingFilter)
    }

    /// filter itself
    let filter: FilterRecord.Filter
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

    private init<X>(from pipeline: Pipeline<In, X>, with filter: FilterRecord.Filter, isJoint: Bool = false) {
        self.filters = pipeline.filters + [FilterRecord(filter: filter/*, outputType: Out.self*/, isJoint: isJoint)]
    }
    
    /// New pipeline with a computing filter appended
    private convenience init<X>(from pipeline: Pipeline<In, X>, with newFilter: @escaping Filter<X, Out>,
                                isJoint: Bool) {
        let wrapper: GeneralizedFilter = { try newFilter($0 as! X) }
        self.init(from: pipeline, with: .computing(wrapper), isJoint: isJoint)
    }
    /// New pipeline with a blocking filter appended
    fileprivate convenience init<X>(from pipeline: Pipeline<In, X>, with newFilter: Blocking<X, Out>) {
        let wrapper: GeneralizedFilter = { try newFilter.filter($0 as! X) }
        self.init(from: pipeline, with: .blocking(wrapper))
    }
    ///  New pipeline with an NIO filter appended
    private convenience init<X>(from pipeline: Pipeline<In, X>, with newFilter: Promising<X, Out>) {
        let wrapper: GeneralizedPromisingFilter = { (evl: EventLoop) in {
            try (newFilter.wrappedFilter(evl)($0 as! X)).map { $0 as Any } } }
        self.init(from: pipeline, with: .nio(wrapper))
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
            switch record.filter {
            case .computing(let filter):
                out = try filter(out)
            case .blocking(let filter):
                out = try filter(out)
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
