#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif

class RWLock {

    var lock = pthread_rwlock_t()

    init() {
        pthread_rwlock_init(&self.lock, nil)
    }

    func rLock() {
        pthread_rwlock_rdlock(&self.lock)
    }

    func rUnlock() {
        pthread_rwlock_unlock(&self.lock)
    }

    func wLock() {
        pthread_rwlock_wrlock(&self.lock)
    }

    func wUnlock() {
        pthread_rwlock_unlock(&self.lock)
    }

    deinit {
        pthread_rwlock_destroy(&self.lock)
    }

}

extension RWLock {

    @inlinable
    public func withRLock<T>(_ body: () throws -> T) rethrows -> T {
        self.rLock()
        defer { self.rUnlock() }
        return try body()
    }

    @inlinable
    public func withRLockVoid(_ body: () throws -> Void) rethrows {
        try self.withRLock(body)
    }

    @inlinable
    public func withWLock<T>(_ body: () throws -> T) rethrows -> T {
        self.wLock()
        defer { self.wUnlock() }
        return try body()
    }

    @inlinable
    public func withWLockVoid(_ body: () throws -> Void) rethrows {
        try self.withWLock(body)
    }

}
