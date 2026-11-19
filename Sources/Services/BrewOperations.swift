import Foundation

/// The one place that lists what brew is doing: mutating commands that are waiting for Homebrew's
/// gate and the one that holds it. `BrewService` reports into it from the gate, so every screen
/// reads the same state instead of keeping its own flags.
///
/// Main-actor observable so SwiftUI can read `operations` directly. The view models keep their own
/// busy flags (`installingNames`, `upgradingPackages`, …) next to it on purpose: each action has one
/// screen that starts it, the flag is set synchronously on the click (this list only fills in once
/// the call reaches the service actor, too late to stop a double click), and it spans the refresh
/// that follows the command, which this list doesn't. What crosses screens — a command waiting
/// behind another one — is read from here.
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

public extension BrewOperations.Kind {
    /// What kind of command `arguments` (a `brew` command line without `brew`) is — for the ones a
    /// `brew doctor` fix can be run as from the Doctor page. Nil for the rest, which stay the user's
    /// to run in Terminal.
    init?(fixArguments arguments: [String]) {
        switch arguments.first {
        case "upgrade": self = .upgrade
        case "install", "reinstall", "postinstall", "link": self = .install
        case "uninstall", "unlink": self = .uninstall
        case "cleanup": self = .cleanup
        case "autoremove": self = .autoremove
        case "tap": self = .tap
        case "untap": self = .untap
        default: return nil
        }
    }
}
