import Dispatch

public class SimpleInMemoryQueue<Elem>: InMemoryQueue {
    public typealias Elem = Elem

    private var queue: [Elem] = []
    private let lock = DispatchSemaphore(value: 1)

    public init(for _: Elem.Type) {}

    public func enqueue(_ item: Elem, options: [String: Any]? = nil) {
        lock.wait()
        defer { lock.signal() }
        self.queue.append(item)
    }

    public func dequeue(options: [String: Any]? = nil) -> Elem? {
        lock.wait()
        defer { lock.signal() }
        return self.queue.popLast()
    }

    public var count: Int {
        return self.queue.count
    }

}
