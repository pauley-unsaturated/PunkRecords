import Foundation

/// Thread-safe recorder for values delivered to a `@Sendable` progress callback
/// from inside an actor. Tests assert against `values` after awaiting the call.
///
/// `@unchecked Sendable` is sound here: every access goes through the lock.
final class ProgressRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
