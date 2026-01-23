import Foundation

enum ConcurrencyHelpers {
    static let defaultTimeout: UInt64 = 10_000_000_000 // 10 seconds

    /// Runs an async operation with a timeout, returning nil if it exceeds the limit
    static func withTimeoutOptional<T: Sendable>(
        nanoseconds: UInt64 = defaultTimeout,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Runs an async operation with a timeout, returning nil if it exceeds the limit
    static func withTimeout<T: Sendable>(
        nanoseconds: UInt64 = defaultTimeout,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Processes items concurrently with a maximum concurrency limit
    static func forEachConcurrent<T: Sendable>(
        _ items: [T],
        maxConcurrent: Int = 4,
        timeout: UInt64 = defaultTimeout,
        operation: @escaping @Sendable (T) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var runningCount = 0
            var index = 0

            while index < items.count {
                if runningCount < maxConcurrent {
                    let item = items[index]
                    group.addTask {
                        _ = await withTimeout(nanoseconds: timeout) {
                            await operation(item)
                            return () as Void
                        }
                    }
                    runningCount += 1
                    index += 1
                } else {
                    await group.next()
                    runningCount -= 1
                }
            }

            while runningCount > 0 {
                await group.next()
                runningCount -= 1
            }
        }
    }

    /// Processes items concurrently and collects results
    static func mapConcurrent<T: Sendable, R: Sendable>(
        _ items: [T],
        maxConcurrent: Int = 4,
        timeout: UInt64 = defaultTimeout,
        operation: @escaping @Sendable (T) async -> R?
    ) async -> [R] {
        await withTaskGroup(of: R?.self) { group in
            var results: [R] = []
            var runningCount = 0
            var index = 0

            while index < items.count {
                if runningCount < maxConcurrent {
                    let item = items[index]
                    group.addTask {
                        await withTimeout(nanoseconds: timeout) {
                            await operation(item)
                        } ?? nil
                    }
                    runningCount += 1
                    index += 1
                } else {
                    if let result = await group.next(), let value = result {
                        results.append(value)
                    }
                    runningCount -= 1
                }
            }

            for await result in group {
                if let value = result {
                    results.append(value)
                }
            }

            return results
        }
    }
}
