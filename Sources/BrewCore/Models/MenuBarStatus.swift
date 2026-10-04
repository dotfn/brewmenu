public enum MenuBarStatus: Equatable, Sendable {
    case initializing
    case ok
    case updates(count: Int)
    case warning(count: Int) // doctor warnings present
    case error(String)
}
