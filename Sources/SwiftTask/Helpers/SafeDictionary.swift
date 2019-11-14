import Foundation

public protocol StringKeyedSafeDictionary {
    subscript(key: String) -> Any? { get set }
    func transaction(body: (_ t: StringKeyedSafeDictionaryTransaction) -> Void)
}
public protocol StringKeyedSafeDictionaryTransaction {
    subscript(key: String) -> Any? { get set }
}

public class SimpleSafeDictionary: StringKeyedSafeDictionary {
    public let dictionary: Box<[String: Any]>
    private let lock = NSLock()
    
    public init(from dictionary: [String: Any] = [String: Any]()) {
        self.dictionary = Box(dictionary)
    }
    
    public subscript(key: String) -> Any? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return dictionary.value[key]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            dictionary.value[key] = newValue
        }
    }
    
    public struct Transaction: StringKeyedSafeDictionaryTransaction {
        fileprivate var dictionary: Box<[String: Any]>
        public subscript(key: String) -> Any? {
            get {
                return dictionary.value[key]
            }
            set {
                dictionary.value[key] = newValue
            }
        }
    }
    
    public func transaction(body: (_ t: StringKeyedSafeDictionaryTransaction) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(Transaction(dictionary: self.dictionary))
    }
}

//public class EmptyStringKeyedDictionary: StringKeyedSafeDictionary {
//    public init() {}
//    public subscript(key: String) -> Any? { get { return nil } set {} }
//    public struct Transaction: StringKeyedSafeDictionaryTransaction {
//        public subscript(key: String) -> Any? { get { return nil } set {} }
//    }
//    static let dummyTransaction = Transaction()
//    public func transaction(body: (_ t: StringKeyedSafeDictionaryTransaction) -> Void) {
//        body(EmptyStringKeyedDictionary.dummyTransaction)
//    }
//}
//public let emptyStringKeyedDictionary = EmptyStringKeyedDictionary()
