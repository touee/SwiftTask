public protocol UnlimitedQueue {
    associatedtype Elem

    func enqueue(_ item: Elem, options: [String: Any]?)
    func dequeue(options: [String: Any]?) -> Elem?

    var count: Int { get }
}

typealias InMemoryQueue = UnlimitedQueue

//public protocol PersistentQueue: UnlimitedQueue where Elem: Packable {}
