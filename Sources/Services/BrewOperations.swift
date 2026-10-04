import Foundation

/// The one place that lists what brew is doing: mutating commands that are waiting for Homebrew's
/// gate and the one that holds it. `BrewService` reports into it from the gate, so every screen
/// reads the same state instead of keeping its own flags.
///
/// Main-actor observable so SwiftUI can read `operations` directly. Phase 1 only records and
/// exposes; the view models still keep their own busy flags until they're moved over.
@MainActor
@Observable
public final class BrewOperations {
    public enum Kind: String, Sendable, CaseIterable {
        case update, upgrade, install, uninstall, tap, untap, cleanup, autoremove
    }

    public struct Operation: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let kind: Kind
        public let subject: String
        /// `true` while waiting for the gate, `false` once it's running.
        public let isQueued: Bool
    }

    public private(set) var operations: [Operation] = []

    public init() {}

    public var running: [Operation] {
        operations.filter { !$0.isQueued }
    }

    public var queued: [Operation] {
        operations.filter(\.isQueued)
    }

    func enqueue(id: UUID, kind: Kind, subject: String) {
        operations.append(Operation(id: id, kind: kind, subject: subject, isQueued: true))
    }

    func start(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        let current = operations[index]
        operations[index] = Operation(id: id, kind: current.kind, subject: current.subject, isQueued: false)
    }

    func remove(id: UUID) {
        operations.removeAll { $0.id == id }
    }
}
