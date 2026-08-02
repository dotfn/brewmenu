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
    ///
    /// Every throw path here reports through `resolver.markBootstrapFailed(_:)` before
    /// rethrowing — without that, a caller suspended in `waitUntilConfigured()` (the
    /// Dashboard opening moments after a launch where Homebrew isn't found, say) would
    /// hang forever: nothing else would ever resume it, since `resolver.configure(...)`
    /// is only reached on the success path.
    func bootstrap(customBrewPath: String? = nil) async throws {
        do {
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
                throw BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            let env = Self.parseShellenv(result.stdout)
            await resolver.configure(brewPath: path, shellEnvironment: env)
            await logger.log("BrewService: bootstrap — brew at \(path)")
        } catch {
            await logger.log("BrewService: bootstrap failed — \(error.localizedDescription)", .error)
            await resolver.markBootstrapFailed(error)
            throw error
        }
    }

    /// Suspends until `bootstrap()` has finished — for callers that may start before
    /// it has (see `DashboardViewModel.load()`). Throws if bootstrap has already failed
    /// (or fails while this is suspended) instead of hanging forever.
    func waitUntilConfigured() async throws {
        try await resolver.waitUntilConfigured()
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

    func searchPackages(_ query: String) async throws -> [SearchResult] {
        let (brewPath, env) = try await resolvedEnvironment()
        // Run concurrently rather than sequentially — `brew search` can't distinguish
        // formula vs. cask in a single unflagged call once output isn't a TTY (no
        // "==> Formulae"/"==> Casks" section headers get printed), so this still needs
        // two spawns, but there's no reason to pay their Ruby-startup cost serially on
        // every debounced keystroke.
        async let formulaResult = runner.run(
            executablePath: brewPath,
            arguments: ["search", "--formula", query],
            environment: env
        )
        async let caskResult = runner.run(
            executablePath: brewPath,
            arguments: ["search", "--cask", query],
            environment: env
        )
        // brew search exits 1 (with "Error: No formulae or casks found") when nothing matches —
        // not a real failure, so we parse whatever stdout is there regardless of exit code.
        let (formula, cask) = try await (formulaResult, caskResult)
        let formulae = Self.parseSearchLines(formula.stdout).map { SearchResult(name: $0, isCask: false) }
        let casks = Self.parseSearchLines(cask.stdout).map { SearchResult(name: $0, isCask: true) }
        return Self.rankedByRelevance(formulae + casks, query: query)
    }

    /// `brew search` already does its own fuzzy/substring matching — it just returns matches in
    /// two flat, separately-alphabetical lists (all formulae, then all casks) with no regard for
    /// how closely each name matches what was typed. An exact hit like "claude" would otherwise
    /// get buried between "claude-code-templates" and "claudekit". This re-ranks by: exact name
    /// match, then prefix match, then substring match — with shorter names (closer to the query)
    /// breaking ties within each tier.
    static func rankedByRelevance(_ results: [SearchResult], query: String) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func tier(_ name: String) -> Int {
            let n = name.lowercased()
            if n == q { return 0 }
            if n.hasPrefix(q) { return 1 }
            if n.contains(q) { return 2 }
            return 3
        }
        return results.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            let ta = tier(a.name), tb = tier(b.name)
            if ta != tb { return ta < tb }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.offset < rhs.offset  // stable: keep original relative order on full ties
        }.map(\.element)
    }

    func fetchInstalledPackages() async throws -> [InstalledPackage] {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["info", "--json=v2", "--installed"],
            environment: env
        )
        guard result.isSuccess, let data = result.stdout.data(using: .utf8) else {
            throw BrewError.outputParsingFailed(command: "info --json=v2 --installed")
        }
        do {
            let output = try JSONDecoder().decode(BrewInfoInstalledOutput.self, from: data)
            return output.installedPackages
        } catch {
            throw BrewError.outputParsingFailed(command: "info --json=v2 --installed")
        }
    }

    /// Looks up a formula/cask name — bare (`wget`) or fully-qualified (`user/repo/name`)
    /// — via `brew info --json=v2`, without installing anything.
    ///
    /// Unlike `install`, `brew info` does *not* auto-tap an unseen repo on its own — it
    /// fails outright with "This command requires the tap user/repo" (confirmed against
    /// a real, legitimate third-party tap during testing). So a fully-qualified name whose
    /// tap isn't tapped yet is tapped here first, then the lookup is retried once; without
    /// this, resolving anything from a tap the user hasn't already added — the main reason
    /// this full-name lookup exists — would always fail.
    func resolvePackage(_ name: String) async throws -> ResolvedPackage? {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["info", "--json=v2", name],
            environment: env
        )
        if result.isSuccess {
            return try Self.decodeResolvedPackage(result.stdout, command: "info --json=v2 \(name)", didAutoTap: false)
        }

        let segments = name.split(separator: "/")
        guard segments.count == 3 else {
            throw BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        let tap = segments[0...1].joined(separator: "/")
        var nonInteractiveEnv = env
        nonInteractiveEnv["HOMEBREW_NO_INTERACTIVE"] = "1"
        let tapResult = try await runner.run(
            executablePath: brewPath,
            arguments: ["tap", tap],
            environment: nonInteractiveEnv
        )
        guard tapResult.isSuccess else {
            // The original "info" failure is the more useful one to show — the tap
            // step's own error is usually a duplicate ("Error: ... requires the tap").
            throw BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }

        let retryResult = try await runner.run(
            executablePath: brewPath,
            arguments: ["info", "--json=v2", name],
            environment: env
        )
        guard retryResult.isSuccess else {
            throw BrewError.commandFailed(exitCode: retryResult.exitCode, stderr: retryResult.stderr)
        }
        return try Self.decodeResolvedPackage(retryResult.stdout, command: "info --json=v2 \(name)", didAutoTap: true)
    }

    private static func decodeResolvedPackage(_ stdout: String, command: String, didAutoTap: Bool) throws -> ResolvedPackage? {
        guard let data = stdout.data(using: .utf8),
              let output = try? JSONDecoder().decode(BrewInfoInstalledOutput.self, from: data) else {
            throw BrewError.outputParsingFailed(command: command)
        }
        return output.firstResolvedPackage(didAutoTap: didAutoTap)
    }

    func fetchTaps() async throws -> [Tap] {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["tap"],
            environment: env
        )
        return Self.parseTaps(result.stdout)
    }

    /// Every formula/cask a tap makes available — not just the ones already
    /// installed from it — so a newly-added, still-empty tap can be browsed
    /// instead of only ever showing "nothing installed yet".
    func fetchTapPackages(_ tap: String) async throws -> [SearchResult] {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["tap-info", "--json=v1", tap],
            environment: env
        )
        guard result.isSuccess, let data = result.stdout.data(using: .utf8) else {
            throw BrewError.outputParsingFailed(command: "tap-info --json=v1 \(tap)")
        }
        do {
            let output = try JSONDecoder().decode([TapInfoOutput].self, from: data)
            guard let info = output.first else { return [] }
            // `cask_tokens` (confirmed empirically against a real third-party tap) come
            // back tap-qualified — "user/repo/name", not bare "name" — unlike every other
            // package name this app displays/installs/matches against. Left as-is, rows
            // for these packages would show the redundant full path instead of the plain
            // name, and installedPackages lookups (which store bare names) would never
            // match them as installed.
            let formulae = info.formulaNames.map { SearchResult(name: Self.stripTapPrefix($0, tap: tap), isCask: false) }
            let casks = info.caskTokens.map { SearchResult(name: Self.stripTapPrefix($0, tap: tap), isCask: true) }
            return (formulae + casks).sorted { $0.name < $1.name }
        } catch {
            throw BrewError.outputParsingFailed(command: "tap-info --json=v1 \(tap)")
        }
    }

    private static func stripTapPrefix(_ name: String, tap: String) -> String {
        let prefix = "\(tap)/"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    func addTap(_ name: String, onLine: @escaping @Sendable (String) -> Void) async throws {
        try await runNonInteractiveStreaming(logVerb: "tap \(name)", arguments: ["tap", name], onLine: onLine)
    }

    /// Removes a tap (`brew untap`) — e.g. cleaning up an empty third-party tap left
    /// behind by a failed `brew install user/repo/name`: Homebrew taps the repo before
    /// resolving the formula/cask, so a nonexistent package name still leaves a real,
    /// empty tap on disk even though the install itself failed.
    func removeTap(_ name: String) async throws {
        await logger.log("BrewService: brew untap \(name) started")
        let (brewPath, env) = try await resolvedEnvironment()
        var nonInteractiveEnv = env
        nonInteractiveEnv["HOMEBREW_NO_INTERACTIVE"] = "1"
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["untap", name],
            environment: nonInteractiveEnv
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            await logger.log("BrewService: brew untap \(name) failed — \(err.localizedDescription)", .error)
            throw err
        }
        await logger.log("BrewService: brew untap \(name) completed")
    }

    func installPackage(_ name: String, isCask: Bool, onLine: @escaping @Sendable (String) -> Void) async throws {
        var arguments = ["install", name]
        if isCask { arguments.insert("--cask", at: 1) }
        try await runNonInteractiveStreaming(logVerb: "install \(name)", arguments: arguments, onLine: onLine)
    }

    func uninstallPackage(_ name: String, isCask: Bool, onLine: @escaping @Sendable (String) -> Void) async throws {
        var arguments = ["uninstall", name]
        if isCask { arguments.insert("--cask", at: 1) }
        try await runNonInteractiveStreaming(logVerb: "uninstall \(name)", arguments: arguments, onLine: onLine)
    }

    /// Runs a non-interactive `brew` subcommand that streams its output line-by-line —
    /// `tap`/`install`/`uninstall` all share this exact shape (env, run, log, throw on
    /// failure), differing only in which arguments they pass and what they log.
    private func runNonInteractiveStreaming(
        logVerb: String,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        await logger.log("BrewService: brew \(logVerb) started")
        let (brewPath, env) = try await resolvedEnvironment()
        var nonInteractiveEnv = env
        nonInteractiveEnv["HOMEBREW_NO_INTERACTIVE"] = "1"
        let result = try await runner.runStreaming(
            executablePath: brewPath,
            arguments: arguments,
            environment: nonInteractiveEnv,
            onLine: onLine
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            await logger.log("BrewService: brew \(logVerb) failed — \(err.localizedDescription)", .error)
            throw err
        }
        await logger.log("BrewService: brew \(logVerb) completed")
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

    /// Actually reclaims disk space (old package versions, download cache) — unlike
    /// `runCleanupDryRun`, this really deletes things. Surfaced from the "Cleanup
    /// pending" insight, behind an explicit confirmation in the UI.
    func runCleanup(onLine: @escaping @Sendable (String) -> Void) async throws {
        await logger.log("BrewService: brew cleanup started")
        let (brewPath, env) = try await resolvedEnvironment()
        var nonInteractiveEnv = env
        nonInteractiveEnv["HOMEBREW_NO_INTERACTIVE"] = "1"
        let result = try await runner.runStreaming(
            executablePath: brewPath,
            arguments: ["cleanup"],
            environment: nonInteractiveEnv,
            onLine: onLine
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            await logger.log("BrewService: brew cleanup failed — \(err.localizedDescription)", .error)
            throw err
        }
        await logger.log("BrewService: brew cleanup completed")
    }

    /// Formulae `brew autoremove` would uninstall — installed only as a dependency
    /// of something else, and nothing needs them anymore. Doesn't touch anything.
    func runAutoremoveDryRun() async throws -> [String] {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["autoremove", "--dry-run"],
            environment: env
        )
        return Self.parseAutoremoveNames(result.stdout)
    }

    /// Actually uninstalls them.
    func runAutoremove(onLine: @escaping @Sendable (String) -> Void) async throws {
        await logger.log("BrewService: brew autoremove started")
        let (brewPath, env) = try await resolvedEnvironment()
        var nonInteractiveEnv = env
        nonInteractiveEnv["HOMEBREW_NO_INTERACTIVE"] = "1"
        let result = try await runner.runStreaming(
            executablePath: brewPath,
            arguments: ["autoremove"],
            environment: nonInteractiveEnv,
            onLine: onLine
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            await logger.log("BrewService: brew autoremove failed — \(err.localizedDescription)", .error)
            throw err
        }
        await logger.log("BrewService: brew autoremove completed")
    }

    /// `brew autoremove --dry-run` prints nothing at all when there's nothing to
    /// remove. When there is, it's an "==> Would autoremove N unneeded formulae:"
    /// header (verified against the real command output) followed by one full
    /// formula name per line — skip the header, keep the rest.
    static func parseAutoremoveNames(_ output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
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
    ///
    /// `HOMEBREW_NO_AUTO_UPDATE` is set for every command: without it, brew can silently
    /// trigger a `brew update`-style git fetch of every tap before running (e.g. `brew info`,
    /// `brew outdated`) whenever its cache looks stale. That fetch can stall for a long time —
    /// or hang indefinitely if a tap's remote ever prompts for credentials with no TTY attached
    /// — turning a simple status read into an unbounded hang. `brew update` itself (`runUpdate`)
    /// isn't gated by this flag — it always does its job regardless.
    private func resolvedEnvironment() async throws -> (brewPath: String, environment: [String: String]) {
        let (path, shellenv) = try await resolver.resolvedState()
        var env = ProcessInfo.processInfo.environment
        env.merge(shellenv) { _, new in new }
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
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

    /// Parses `brew search --formula`/`--cask` output (one package name per line, no headers
    /// since each flag scopes to a single kind — unlike plain `brew search` which prints
    /// "==> Formulae"/"==> Casks" section headers).
    static func parseSearchLines(_ output: String) -> [String] {
        output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parses `brew tap` output (one tap name per line, e.g. "homebrew/core").
    static func parseTaps(_ output: String) -> [Tap] {
        output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Tap(name: $0) }
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
