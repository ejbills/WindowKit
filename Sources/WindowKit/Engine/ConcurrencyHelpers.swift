import Foundation

enum ConcurrencyHelpers {
    static let defaultTimeoutSeconds: TimeInterval = 10

    static func withTimeoutOptional<T: Sendable>(
        seconds: TimeInterval = defaultTimeoutSeconds,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    static func withTimeout<T: Sendable>(
        seconds: TimeInterval = defaultTimeoutSeconds,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    static func forEachConcurrent<T: Sendable>(
        _ items: [T],
        maxConcurrent: Int = 4,
        timeout: TimeInterval? = nil,
        operation: @Sendable @escaping (T) async throws -> Void
    ) async {
        guard !items.isEmpty else { return }

        if let timeout {
            await withTimeout(seconds: timeout) {
                await performForEachConcurrent(items, maxConcurrent: maxConcurrent, operation: operation)
            }
        } else {
            await performForEachConcurrent(items, maxConcurrent: maxConcurrent, operation: operation)
        }
    }

    private static func performForEachConcurrent<T: Sendable>(
        _ items: [T],
        maxConcurrent: Int,
        operation: @Sendable @escaping (T) async throws -> Void
    ) async {
        let concurrency = max(1, min(maxConcurrent, items.count))

        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()

            for _ in 0..<concurrency {
                guard !Task.isCancelled else { return }
                if let item = iterator.next() {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        try? await operation(item)
                    }
                }
            }

            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let item = iterator.next() {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        try? await operation(item)
                    }
                }
            }
        }
    }

    static func mapConcurrent<T: Sendable, R: Sendable>(
        _ items: [T],
        maxConcurrent: Int = 4,
        timeout: TimeInterval? = nil,
        operation: @Sendable @escaping (T) async -> R?
    ) async -> [R] {
        guard !items.isEmpty else { return [] }

        if let timeout {
            return await withTimeout(seconds: timeout) {
                await performMapConcurrent(items, maxConcurrent: maxConcurrent, operation: operation)
            } ?? []
        } else {
            return await performMapConcurrent(items, maxConcurrent: maxConcurrent, operation: operation)
        }
    }

    private static func performMapConcurrent<T: Sendable, R: Sendable>(
        _ items: [T],
        maxConcurrent: Int,
        operation: @Sendable @escaping (T) async -> R?
    ) async -> [R] {
        let concurrency = max(1, min(maxConcurrent, items.count))

        return await withTaskGroup(of: R?.self) { group in
            var results: [R] = []
            results.reserveCapacity(items.count)
            var iterator = items.makeIterator()

            for _ in 0..<concurrency {
                guard !Task.isCancelled else { return results }
                if let item = iterator.next() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await operation(item)
                    }
                }
            }

            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return results
                }
                if let value = result {
                    results.append(value)
                }
                if let item = iterator.next() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await operation(item)
                    }
                }
            }

            return results
        }
    }
}
