import Foundation

actor BrewService {
    private let resolver: EnvironmentResolver
    private let runner: any ProcessRunner
    private let logger = BrewLogger.shared

    init(resolver: EnvironmentResolver, runner: any ProcessRunner = SystemProcessRunner()) {
        self.resolver = resolver
        self.runner = runner
    }

    // MARK: - Bootstrap

    /// Detects the brew binary and resolves the shell environment via `brew shellenv`.
    /// Must be called once before any other method.
    func bootstrap(customBrewPath: String? = nil) async throws {
        let path = try await resolver.detectBrewPath(customPath: customBrewPath)

        // Merge with ProcessInfo env so brew has HOME, USER, TMPDIR, etc.
        // Setting Process.environment replaces the entire env — a minimal dict breaks brew.
        var bootstrapEnv = ProcessInfo.processInfo.environment
        bootstrapEnv["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let result = try await runner.run(
            executablePath: path,
            arguments: ["shellenv", "--shell=bash"],
            environment: bootstrapEnv
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            await logger.log("BrewService: bootstrap failed — \(err.localizedDescription)", .error)
            throw err
        }
        let env = Self.parseShellenv(result.stdout)
        await resolver.configure(brewPath: path, shellEnvironment: env)
        await logger.log("BrewService: bootstrap — brew at \(path)")
    }

    // MARK: - Commands

    func fetchOutdated() async throws -> [OutdatedPackage] {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["outdated", "--json=v2"],
            environment: env
        )
        // brew outdated exits 0 (none outdated) or 1 (some outdated) — both have valid JSON output.
        guard let data = result.stdout.data(using: .utf8) else {
            throw BrewError.outputParsingFailed(command: "outdated --json=v2")
        }
        do {
            let output = try JSONDecoder().decode(OutdatedCommandOutput.self, from: data)
            return output.formulae + output.casks
        } catch {
            throw BrewError.outputParsingFailed(command: "outdated --json=v2")
        }
    }

    func runUpdate() async throws {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["update"],
            environment: env
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            await logger.log("BrewService: brew update failed — \(err.localizedDescription)", .error)
            throw err
        }
    }

    func runUpgrade(_ name: String) async throws {
        await logger.log("BrewService: brew upgrade \(name) started")
        let (brewPath, env) = try await resolvedEnvironment()
        var nonInteractiveEnv = env
        nonInteractiveEnv["HOMEBREW_NO_INTERACTIVE"] = "1"
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["upgrade", name],
            environment: nonInteractiveEnv
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            await logger.log("BrewService: brew upgrade \(name) failed — \(err.localizedDescription)", .error)
            throw err
        }
        await logger.log("BrewService: brew upgrade \(name) completed")
    }

    func runUpgrade(names: [String], onLine: @escaping @Sendable (String) -> Void) async throws {
        await logger.log("BrewService: brew upgrade \(names.joined(separator: " ")) started")
        let (brewPath, env) = try await resolvedEnvironment()
        var nonInteractiveEnv = env
        nonInteractiveEnv["HOMEBREW_NO_INTERACTIVE"] = "1"
        let result = try await runner.runStreaming(
            executablePath: brewPath,
            arguments: ["upgrade"] + names,
            environment: nonInteractiveEnv,
            onLine: onLine
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            await logger.log("BrewService: brew upgrade failed — \(err.localizedDescription)", .error)
            throw err
        }
        await logger.log("BrewService: brew upgrade \(names.joined(separator: " ")) completed")
    }

    func runUpgradeAll(onLine: @escaping @Sendable (String) -> Void) async throws {
        await logger.log("BrewService: brew upgrade started")
        let (brewPath, env) = try await resolvedEnvironment()
        // HOMEBREW_NO_INTERACTIVE prevents brew from waiting for stdin input
        // (cask upgrade prompts, app-close confirmations) when running without a TTY.
        var nonInteractiveEnv = env
        nonInteractiveEnv["HOMEBREW_NO_INTERACTIVE"] = "1"
        let result = try await runner.runStreaming(
            executablePath: brewPath,
            arguments: ["upgrade"],
            environment: nonInteractiveEnv,
            onLine: onLine
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            await logger.log("BrewService: brew upgrade failed — \(err.localizedDescription)", .error)
            throw err
        }
        await logger.log("BrewService: brew upgrade completed")
    }

    func fetchInstalledCasks() async throws -> [CaskEntry] {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["list", "--cask", "--versions"],
            environment: env
        )
        // Non-zero exit is not always fatal — some brew versions exit 1 when no casks are installed.
        return Self.parseInstalledCasks(result.stdout)
    }

    func fetchServices() async throws -> [ServiceEntry] {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["services", "list", "--json"],
            environment: env
        )
        guard result.isSuccess, let data = result.stdout.data(using: .utf8) else {
            throw BrewError.outputParsingFailed(command: "services list --json")
        }
        do {
            return try JSONDecoder().decode([ServiceEntry].self, from: data)
        } catch {
            throw BrewError.outputParsingFailed(command: "services list --json")
        }
    }

    func startService(_ name: String) async throws {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["services", "start", name],
            environment: env
        )
        guard result.isSuccess else {
            throw BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    func stopService(_ name: String) async throws {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["services", "stop", name],
            environment: env
        )
        guard result.isSuccess else {
            throw BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    func runCleanupDryRun() async throws -> Int64 {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["cleanup", "--dry-run"],
            environment: env
        )
        // brew cleanup --dry-run exits 0 regardless of whether there's anything to clean.
        return Self.parseCleanupBytes(result.stdout)
    }

    func runDoctor() async throws -> [DoctorWarning] {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["doctor"],
            environment: env
        )
        // brew doctor exits 0 (healthy) or 1 (warnings/errors found) — both have parseable output.
        let warnings = Self.parseDoctorOutput(result.stdout)
        if warnings.isEmpty {
            await logger.log("BrewService: brew doctor — healthy")
        } else {
            let errors = warnings.filter { $0.severity == .error }.count
            let warns  = warnings.filter { $0.severity == .warning }.count
            await logger.log("BrewService: brew doctor — \(errors) error(s), \(warns) warning(s)", .warn)
        }
        return warnings
    }

    // MARK: - Private

    /// Builds the full process environment: system env as base, with Homebrew vars overlaid.
    private func resolvedEnvironment() async throws -> (brewPath: String, environment: [String: String]) {
        let (path, shellenv) = try await resolver.resolvedState()
        var env = ProcessInfo.processInfo.environment
        env.merge(shellenv) { _, new in new }
        return (path, env)
    }

    /// Parses `brew cleanup --dry-run` output and returns the number of reclaimable bytes.
    /// The relevant line looks like: "==> This operation would free approximately 1.2 GB of disk space."
    static func parseCleanupBytes(_ output: String) -> Int64 {
        for line in output.components(separatedBy: "\n").reversed() {
            let lower = line.lowercased()
            guard lower.contains("would free") else { continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            for (i, part) in parts.enumerated() {
                let normalized = part.replacingOccurrences(of: ",", with: ".")
                guard let value = Double(normalized), value > 0 else { continue }
                let unit = i + 1 < parts.count ? parts[i + 1].uppercased() : ""
                switch unit {
                case "GB", "GIB": return Int64(value * 1_073_741_824)
                case "MB", "MIB": return Int64(value * 1_048_576)
                case "KB", "KIB": return Int64(value * 1_024)
                case "B":         return Int64(value)
                default:          continue
                }
            }
        }
        return 0
    }

    /// Parses `brew list --cask --versions` output into CaskEntry values.
    /// Each line has the form: "name version" (e.g. "alfred 5.5.2" or "iterm2 3.5.0").
    static func parseInstalledCasks(_ output: String) -> [CaskEntry] {
        output
            .components(separatedBy: "\n")
            .compactMap { line -> CaskEntry? in
                let parts = line
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                guard parts.count >= 2 else { return nil }
                return CaskEntry(name: parts[0], version: parts[1])
            }
    }

    /// Parses `brew doctor` text output into structured warnings.
    /// Paragraphs separated by blank lines; relevant ones start with "Warning:" or "Error:".
    static func parseDoctorOutput(_ output: String) -> [DoctorWarning] {
        output
            .components(separatedBy: "\n\n")
            .compactMap { paragraph -> DoctorWarning? in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("Error:") {
                    return DoctorWarning(severity: .error, message: trimmed)
                } else if trimmed.hasPrefix("Warning:") {
                    return DoctorWarning(severity: .warning, message: trimmed)
                }
                return nil
            }
    }

    /// Parses `brew shellenv --shell=bash` output into a `[String: String]` dictionary.
    /// Lines look like: export KEY="value";
    private static func parseShellenv(_ output: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("export ") else { continue }
            trimmed = String(trimmed.dropFirst(7)) // "export ".count == 7
            if trimmed.hasSuffix(";") { trimmed = String(trimmed.dropLast()) }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex])
            var value = String(trimmed[trimmed.index(after: eqIndex)...])
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            env[key] = value
        }
        return env
    }
}
