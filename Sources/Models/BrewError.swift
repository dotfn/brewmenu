enum BrewError: Error, Equatable {
    case notFound(searchedPaths: [String])
    case notConfigured
    case commandFailed(exitCode: Int32, stderr: String)
    case outputParsingFailed(command: String)
}
