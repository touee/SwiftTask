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

public struct WithData<T> {
    public let innerFilter: (StringKeyedSafeDictionary, StringKeyedSafeDictionary) -> T
}

public struct GeneralizedFilter {
    private let filter: Any
    public let isPromising: Bool
    public let withExtraData: Bool
    
    public init<In, Out>(filter: @escaping Filter<In, Out>) {
        self.filter = { (input: Any) -> Any in try filter(input as! In) }
        self.isPromising = false
        self.withExtraData = false
    }
    public init<In, Out>(filter: WithData<Filter<In, Out>>) {
        self.filter = { (shared: StringKeyedSafeDictionary, owned: StringKeyedSafeDictionary) in
                { (input: Any) -> Any in try filter.innerFilter(shared, owned)(input as! In) }
            }
        self.isPromising = false
        self.withExtraData = true
    }
    public init<In, Out>(filter: Blocking<In, Out>) {
        self.init(filter: filter.filter)
    }
    public init<In, Out>(filter: WithData<Blocking<In, Out>>) {
        self.filter = { (shared: StringKeyedSafeDictionary, owned: StringKeyedSafeDictionary) in
            { (input: Any) -> Any in try filter.innerFilter(shared, owned).filter(input as! In) }
        }
        self.isPromising = false
        self.withExtraData = true
    }
    public init<In, Out>(filter: Promising<In, Out>) {
        self.filter = { (evl: EventLoop) in { (input: Any) -> Any in
            try (filter.wrappedFilter(evl)(input as! In)).map { $0 as Any } } }
        self.isPromising = true
        self.withExtraData = false
    }
    public init<In, Out>(filter: WithData<Promising<In, Out>>) {
        self.filter = { (shared: StringKeyedSafeDictionary, owned: StringKeyedSafeDictionary) in
            { (evl: EventLoop) in { (input: Any) -> Any in
                try (filter.innerFilter(shared, owned).wrappedFilter(evl)(input as! In)).map { $0 as Any } } }
            }
        self.isPromising = true
        self.withExtraData = true
    }
    
    public func execute(input: Any, eventLoop: EventLoop? = nil,
                        sharedData: StringKeyedSafeDictionary? = nil,
                        ownedData: StringKeyedSafeDictionary? = nil) throws -> Any {
        var filter: Any = self.filter
        // Could not cast value of type '(SwiftTask.StringKeyedSafeDictionary, SwiftTask.StringKeyedSafeDictionary) -> (NIO.EventLoop) -> (Any) throws -> Any' (0x7fffa083f838) to '(SwiftTask.StringKeyedSafeDictionary, SwiftTask.StringKeyedSafeDictionary) -> Any' (0x7fffa0844278).
        // I'm certain that swift can cast (…) -> … to (…) -> Any, no wonder why it failed here
//        if self.withExtraData {
//            filter = (filter as! (StringKeyedSafeDictionary, StringKeyedSafeDictionary) -> Any)(sharedData!, ownedData!)
//        }
        if self.withExtraData {
            if self.isPromising {
                filter = (filter as! (StringKeyedSafeDictionary, StringKeyedSafeDictionary) -> (EventLoop) -> (Any) throws -> Any)(sharedData!, ownedData!)
            } else {
                filter = (filter as! (StringKeyedSafeDictionary, StringKeyedSafeDictionary) -> (Any) throws -> Any)(sharedData!, ownedData!)
            }
        }
        if self.isPromising {
            filter = (filter as! (EventLoop) -> (Any) throws -> Any)(eventLoop!)
        }
        return try (filter as! ((Any) throws -> Any))(input)
    }
    public func executePromising(input: Any, eventLoop: EventLoop,
                                 sharedData: StringKeyedSafeDictionary? = nil,
                                 ownedData: StringKeyedSafeDictionary? = nil) throws -> EventLoopFuture<Any> {
        return try self.execute(input: input, eventLoop: eventLoop, sharedData: sharedData, ownedData: ownedData) as! EventLoopFuture<Any>
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
    public let filterType: FilterType
    public let filter: GeneralizedFilter
//    /// filter's return type
//    let outputType: Any.Type
    public let isJoint: Bool
}

/// A Pipeline is a composition of filters.
public final class Pipeline<In, Out> {
    /// composited filters
    public let filters: [FilterRecord]

    /// A nop pipeline for constructing new pipelines.
    fileprivate init() {
        self.filters = []
    }

    fileprivate init<X>(from pipeline: Pipeline<In, X>, with filterRecord: FilterRecord) {
        self.filters = pipeline.filters + [filterRecord]
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

    /// New pipeline with a computing filter appended
    public static func | <X>(lhs: Pipeline<In, X>, rhs: @escaping Filter<X, Out>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: FilterRecord(
            filterType: .computing,
            filter: GeneralizedFilter(filter: rhs),
            isJoint: false))
    }
    public static func | <X>(lhs: Pipeline<In, X>, rhs: WithData<Filter<X, Out>>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: FilterRecord(
            filterType: .computing,
            filter: GeneralizedFilter(filter: rhs),
            isJoint: false))
    }
    public static func |+ <X>(lhs: Pipeline<In, X>, rhs: @escaping Filter<X, Out>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: FilterRecord(
            filterType: .computing,
            filter: GeneralizedFilter(filter: rhs),
            isJoint: true))
    }
    public static func |+ <X>(lhs: Pipeline<In, X>, rhs: WithData<Filter<X, Out>>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: FilterRecord(
            filterType: .computing,
            filter: GeneralizedFilter(filter: rhs),
            isJoint: true))
    }
    /// New pipeline with a blocking filter appended
    public static func | <X>(lhs: Pipeline<In, X>, rhs: Blocking<X, Out>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: FilterRecord(
            filterType: .blocking,
            filter: GeneralizedFilter(filter: rhs),
            isJoint: false))
    }
    public static func | <X>(lhs: Pipeline<In, X>, rhs: WithData<Blocking<X, Out>>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: FilterRecord(
            filterType: .blocking,
            filter: GeneralizedFilter(filter: rhs),
            isJoint: false))
    }
    ///  New pipeline with an NIO filter appended
    public static func | <X>(lhs: Pipeline<In, X>, rhs: Promising<X, Out>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: FilterRecord(
            filterType: .nio,
            filter: GeneralizedFilter(filter: rhs),
            isJoint: false))
    }
    public static func | <X>(lhs: Pipeline<In, X>, rhs: WithData<Promising<X, Out>>) -> Pipeline<In, Out> {
        return Pipeline(from: lhs, with: FilterRecord(
            filterType: .nio,
            filter: GeneralizedFilter(filter: rhs),
            isJoint: false))
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
