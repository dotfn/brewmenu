import Foundation

struct WaitTimeout: Error {}

/// Polls `condition` until it holds, failing after `timeout`. The deterministic
/// replacement for a fixed sleep, which is what made these tests flaky under load.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(5))
    }
}
