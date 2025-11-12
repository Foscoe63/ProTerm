import Foundation
import os.lock
import Combine

// Lightweight atomic boolean using os_unfair_lock.
// Marked @unchecked Sendable for use across threads.
final class AtomicBool: @unchecked Sendable {
    private var value: Bool
    private var lock = os_unfair_lock_s()
    
    init(_ initial: Bool) {
        self.value = initial
    }
    
    func set(_ newValue: Bool) {
        os_unfair_lock_lock(&lock)
        value = newValue
        os_unfair_lock_unlock(&lock)
    }
    
    func get() -> Bool {
        os_unfair_lock_lock(&lock)
        let v = value
        os_unfair_lock_unlock(&lock)
        return v
    }
}
