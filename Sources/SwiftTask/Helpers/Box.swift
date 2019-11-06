
public class Box<T> {
    public var value: T
    
    public init(_ value: T) {
        self.value = value
    }
}

public func box<T>(_ builder: () -> (T)) -> Box<T> {
    return Box(builder())
}
