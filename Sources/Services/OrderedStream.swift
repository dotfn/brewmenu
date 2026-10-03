import Foundation

/// Hands values from a background callback to the main actor, strictly in the order they
/// were produced. A `Task` per value gives no ordering guarantee, so streamed brew output
/// could land out of order, or after the next run had already cleared its log.
struct OrderedStream<T: Sendable>: Sendable {
    let send: @Sendable (T) -> Void
    let finish: @Sendable () -> Void
}

/// `handle` runs on the main actor, one value at a time, in send order. Call `finish()`
/// when the run ends so the consuming task can exit.
func makeOrderedStream<T: Sendable>(_ handle: @escaping @MainActor (T) -> Void) -> OrderedStream<T> {
    let (stream, continuation) = AsyncStream<T>.makeStream()
    Task { @MainActor in
        for await value in stream { handle(value) }
    }
    return OrderedStream(send: { continuation.yield($0) }, finish: { continuation.finish() })
}
