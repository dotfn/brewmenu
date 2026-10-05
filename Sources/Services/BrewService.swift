import BrewCore
import Foundation

actor BrewService {
    private let resolver: EnvironmentResolver
    private let runner: any ProcessRunner
    private let operations: BrewOperations?
    private let logger = BrewLogger.shared
    /// The path the last `bootstrap` was asked for — reused when a later call has to
    /// bootstrap again (see `resolvedEnvironment()`).
    private var customBrewPath: String?

    init(
        resolver: EnvironmentResolver,
        runner: any ProcessRunner = SystemProcessRunner(),
        operations: BrewOperations? = nil
    ) {
        self.resolver = resolver
        self.runner = runner
        self.operations = operations
    }

    // MARK: - Homebrew lock

    /// Homebrew takes its own lock for every mutating command, so two of them running
    /// at once fail with lock errors. Every mutating entry point below takes this gate
    /// first: they queue FIFO and run one at a time, whichever screen started them. A
    /// waiter cancelled while queued leaves the queue and never runs.
    private var lockHeld = false
    private var lockWaiters: [(id: UUID, resume: CheckedContinuation<Void, Error>)] = []

    private func acquireGate() async throws {
        guard lockHeld else { lockHeld = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await waitForBrewLock(id)
        } onCancel: {
            Task { await self.cancelLockWaiter(id) }
        }
    }

    private func waitForBrewLock(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Cancelled before queueing — onCancel's cleanup can't see us, so bail here.
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            lockWaiters.append((id, continuation))
        }
    }

    /// Hands the lock straight to the next waiter (it stays held), or frees it.
    /// Takes the gate for one mutating command and registers it, so waiting and running commands
    /// are visible in one place (see `BrewOperations`).
    private func acquireBrewLock(_ kind: BrewOperations.Kind, _ subject: String) async throws -> UUID {
        let id = UUID()
        await operations?.enqueue(id: id, kind: kind, subject: subject)
        do {
            try await acquireGate()
        } catch {
            await operations?.remove(id: id)
            throw error
        }
        await operations?.start(id: id)
        return id
    }

    /// Releases the gate and drops the command from the log.
    private func releaseBrewLock(_ id: UUID) {
        releaseGate()
        Task { [operations] in await operations?.remove(id: id) }
    }

    private func releaseGate() {
        guard !lockWaiters.isEmpty else { lockHeld = false; return }
        lockWaiters.removeFirst().resume.resume()
    }

    private func cancelLockWaiter(_ id: UUID) {
        guard let index = lockWaiters.firstIndex(where: { $0.id == id }) else { return }
        lockWaiters.remove(at: index).resume.resume(throwing: CancellationError())
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
        self.customBrewPath = customBrewPath
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
                throw BrewError.commandFailed(
                    exitCode: result.exitCode,
                    stderr: result.stderr,
                    command: BrewError.commandLine(["shellenv", "--shell=bash"])
                )
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
        let operation = try await acquireBrewLock(.update, "taps")
        defer { releaseBrewLock(operation) }
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["update"],
            environment: env
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["update"])
            )
            await logger.log("BrewService: brew update failed — \(err.localizedDescription)", .error)
            throw err
        }
    }

    func runUpgrade(_ name: String, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let operation = try await acquireBrewLock(.upgrade, name)
        defer { releaseBrewLock(operation) }
        await logger.log("BrewService: brew upgrade \(name) started")
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.runStreaming(
            executablePath: brewPath,
            arguments: ["upgrade", name],
            environment: env,
            onLine: onLine
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["upgrade", name])
            )
            await logger.log("BrewService: brew upgrade \(name) failed — \(err.localizedDescription)", .error)
            throw err
        }
        await logger.log("BrewService: brew upgrade \(name) completed")
    }

    /// Upgrades exactly `names`. Naming them, rather than a bare `brew upgrade`, lets the caller
    /// leave packages out — e.g. BrewMenu's own cask, which must not replace the running app.
    func runUpgradeAll(names: [String], onLine: @escaping @Sendable (String) -> Void) async throws {
        guard !names.isEmpty else { return }
        let operation = try await acquireBrewLock(.upgrade, names.joined(separator: ", "))
        defer { releaseBrewLock(operation) }
        await logger.log("BrewService: brew upgrade started (\(names.count) packages)")
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.runStreaming(
            executablePath: brewPath,
            arguments: ["upgrade"] + names,
            environment: env,
            onLine: onLine
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["upgrade"] + names)
            )
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
        // `--` stops brew's own option parsing before `query` — without it, a query
        // starting with "-" (e.g. "-x") is read as an unknown flag instead of search
        // text: brew prints its usage text (still exit 0) instead of searching, and
        // that usage text would otherwise get parsed below as if it were real results.
        async let formulaResult = runner.run(
            executablePath: brewPath,
            arguments: ["search", "--formula", "--", query],
            environment: env
        )
        async let caskResult = runner.run(
            executablePath: brewPath,
            arguments: ["search", "--cask", "--", query],
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
            return lhs.offset < rhs.offset // stable: keep original relative order on full ties
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
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let output = try decoder.decode(BrewInfoInstalledOutput.self, from: data)
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
            throw BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["info", "--json=v2", name])
            )
        }
        let tap = segments[0 ... 1].joined(separator: "/")
        let tapResult = try await runner.run(
            executablePath: brewPath,
            arguments: ["tap", tap],
            environment: env
        )
        guard tapResult.isSuccess else {
            // The original "info" failure is the more useful one to show — the tap
            // step's own error is usually a duplicate ("Error: ... requires the tap").
            throw BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["tap", tap])
            )
        }

        let retryResult = try await runner.run(
            executablePath: brewPath,
            arguments: ["info", "--json=v2", name],
            environment: env
        )
        guard retryResult.isSuccess else {
            throw BrewError.commandFailed(
                exitCode: retryResult.exitCode,
                stderr: retryResult.stderr,
                command: BrewError.commandLine(["info", "--json=v2", name])
            )
        }
        return try Self.decodeResolvedPackage(retryResult.stdout, command: "info --json=v2 \(name)", didAutoTap: true)
    }

    private static func decodeResolvedPackage(_ stdout: String, command: String,
                                              didAutoTap: Bool) throws -> ResolvedPackage?
    {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = stdout.data(using: .utf8),
              let output = try? decoder.decode(BrewInfoInstalledOutput.self, from: data)
        else {
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
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let output = try decoder.decode([TapInfoOutput].self, from: data)
            guard let info = output.first else { return [] }
            // `cask_tokens` (confirmed empirically against a real third-party tap) come
            // back tap-qualified — "user/repo/name", not bare "name" — unlike every other
            // package name this app displays/installs/matches against. Left as-is, rows
            // for these packages would show the redundant full path instead of the plain
            // name, and installedPackages lookups (which store bare names) would never
            // match them as installed.
            let formulae = info.formulaNames
                .map { SearchResult(name: Self.stripTapPrefix($0, tap: tap), isCask: false) }
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
        let operation = try await acquireBrewLock(.tap, name)
        defer { releaseBrewLock(operation) }
        try await runNonInteractiveStreaming(logVerb: "tap \(name)", arguments: ["tap", name], onLine: onLine)
    }

    /// Removes a tap (`brew untap`) — e.g. cleaning up an empty third-party tap left
    /// behind by a failed `brew install user/repo/name`: Homebrew taps the repo before
    /// resolving the formula/cask, so a nonexistent package name still leaves a real,
    /// empty tap on disk even though the install itself failed.
    func removeTap(_ name: String) async throws {
        let operation = try await acquireBrewLock(.untap, name)
        defer { releaseBrewLock(operation) }
        await logger.log("BrewService: brew untap \(name) started")
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(
            executablePath: brewPath,
            arguments: ["untap", name],
            environment: env
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["untap", name])
            )
            await logger.log("BrewService: brew untap \(name) failed — \(err.localizedDescription)", .error)
            throw err
        }
        await logger.log("BrewService: brew untap \(name) completed")
    }

    func installPackage(
        _ name: String,
        isCask: Bool,
        onLine: @escaping @Sendable (String) -> Void,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        let operation = try await acquireBrewLock(.install, name)
        defer { releaseBrewLock(operation) }
        var arguments = ["install", name]
        if isCask { arguments.insert("--cask", at: 1) }
        try await runNonInteractiveStreaming(
            logVerb: "install \(name)",
            arguments: arguments,
            onLine: onLine,
            onProgress: onProgress
        )
    }

    func uninstallPackage(_ name: String, isCask: Bool, onLine: @escaping @Sendable (String) -> Void) async throws {
        let operation = try await acquireBrewLock(.uninstall, name)
        defer { releaseBrewLock(operation) }
        var arguments = ["uninstall", name]
        if isCask { arguments.insert("--cask", at: 1) }
        try await runNonInteractiveStreaming(
            logVerb: "uninstall \(name)",
            arguments: arguments,
            onLine: onLine,
            onProgress: nil
        )
    }

    /// Runs a non-interactive `brew` subcommand that streams its output line-by-line —
    /// `tap`/`install`/`uninstall` all share this exact shape (env, run, log, throw on
    /// failure), differing only in which arguments they pass and what they log.
    private func runNonInteractiveStreaming(
        logVerb: String,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        await logger.log("BrewService: brew \(logVerb) started")
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.runStreaming(
            executablePath: brewPath,
            arguments: arguments,
            environment: env,
            onLine: onLine,
            onProgress: onProgress
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(arguments)
            )
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
        let malformed = Self.malformedCaskLines(result.stdout)
        if !malformed.isEmpty {
            await logger.log(
                "BrewService: skipped \(malformed.count) cask line(s) it couldn't parse, e.g. \(malformed[0])",
                .warn
            )
        }
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
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode([ServiceEntry].self, from: data)
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
            throw BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["services", "start", name])
            )
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
            throw BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["services", "stop", name])
            )
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
        let operation = try await acquireBrewLock(.cleanup, "cache")
        defer { releaseBrewLock(operation) }
        await logger.log("BrewService: brew cleanup started")
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.runStreaming(
            executablePath: brewPath,
            arguments: ["cleanup"],
            environment: env,
            onLine: onLine
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["cleanup"])
            )
            await logger.log("BrewService: brew cleanup failed — \(err.localizedDescription)", .error)
            throw err
        }
        await logger.log("BrewService: brew cleanup completed")
    }

    /// Lists the files actually sitting in Homebrew's download cache — the ground
    /// truth of what's using disk space there, rather than `brew cleanup`'s own
    /// age-based idea of what's worth keeping (see `clearCache()`).
    func fetchCacheEntries() async throws -> [CacheEntry] {
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.run(executablePath: brewPath, arguments: ["--cache"], environment: env)
        guard result.isSuccess else {
            throw BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["--cache"])
            )
        }
        let cacheDir = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.listCacheEntries(at: cacheDir)
    }

    static func listCacheEntries(at directoryPath: String) -> [CacheEntry] {
        guard !directoryPath.isEmpty else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directoryPath),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.compactMap { url -> CacheEntry? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return CacheEntry(
                path: url,
                sizeBytes: Int64(values.fileSize ?? 0),
                modifiedDate: values.contentModificationDate ?? .distantPast
            )
        }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Deletes one cached download — brew re-downloads it if it's ever needed again,
    /// so this is always safe.
    func deleteCacheEntry(_ entry: CacheEntry) async throws {
        try FileManager.default.removeItem(at: entry.path)
    }

    /// Empties the whole cache directory — a plain filesystem wipe rather than
    /// `brew cleanup`, which by default only prunes entries older than
    /// `HOMEBREW_CLEANUP_MAX_AGE_DAYS` (120) and also touches old Cellar versions, a
    /// separate concern `runCleanup` already covers. Best-effort per file, so one
    /// locked/in-use download doesn't block clearing the rest.
    func clearCache() async throws {
        for entry in try await fetchCacheEntries() {
            try? FileManager.default.removeItem(at: entry.path)
        }
    }

    /// Real on-disk size of each given package's Cellar (formula) or Caskroom
    /// (cask) directory — sized concurrently since this walks every file in every
    /// package's directory tree and sequential I/O for 100+ packages would make the
    /// "Disk Usage" tool noticeably slow to open.
    func fetchPackageDiskUsage(for packages: [(name: String, isCask: Bool)]) async throws -> [PackageDiskUsage] {
        let (_, env) = try await resolvedEnvironment()
        guard let cellar = env["HOMEBREW_CELLAR"], let prefix = env["HOMEBREW_PREFIX"] else {
            throw BrewError.outputParsingFailed(command: "shellenv (missing HOMEBREW_CELLAR/HOMEBREW_PREFIX)")
        }
        // Casks always live directly under "<prefix>/Caskroom/<name>" — a Homebrew
        // convention, not something `brew shellenv` exports a variable for.
        let caskroom = "\(prefix)/Caskroom"
        let targets = packages.map { package in
            (
                name: package.name,
                isCask: package.isCask,
                dir: package.isCask ? "\(caskroom)/\(package.name)" : "\(cellar)/\(package.name)"
            )
        }
        // Each walk is blocking file I/O. Running them as child tasks would park one
        // cooperative-pool thread per package (hundreds, with a big Cellar), so they run on
        // a dedicated queue with a fixed width instead.
        return await withCheckedContinuation { (continuation: CheckedContinuation<[PackageDiskUsage], Never>) in
            DispatchQueue.global(qos: .utility).async {
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 4
                let results = DiskUsageResults()
                for target in targets {
                    queue.addOperation {
                        results.add(PackageDiskUsage(
                            name: target.name,
                            isCask: target.isCask,
                            sizeBytes: Self.directorySizeBytes(at: target.dir)
                        ))
                    }
                }
                queue.waitUntilAllOperationsAreFinished()
                continuation.resume(returning: results.sorted())
            }
        }
    }

    /// Recursively sums file sizes under `path` — `.totalFileAllocatedSizeKey` (actual
    /// blocks on disk) rather than `.fileSizeKey` (logical byte count), so this matches
    /// what `du`/Finder's "on disk" size reports instead of undercounting.
    static func directorySizeBytes(at path: String) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
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
        let operation = try await acquireBrewLock(.autoremove, "unused dependencies")
        defer { releaseBrewLock(operation) }
        await logger.log("BrewService: brew autoremove started")
        let (brewPath, env) = try await resolvedEnvironment()
        let result = try await runner.runStreaming(
            executablePath: brewPath,
            arguments: ["autoremove"],
            environment: env,
            onLine: onLine
        )
        guard result.isSuccess else {
            let err = BrewError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.stderr,
                command: BrewError.commandLine(["autoremove"])
            )
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
            let errors = warnings.count(where: { $0.severity == .error })
            let warns = warnings.count(where: { $0.severity == .warning })
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
        // Homebrew may have been installed after launch, or the first bootstrap may have
        // failed. Bootstrap again here instead of failing every operation until a relaunch
        // (the Retry button and the hourly status check both go through this).
        if await !(resolver.isConfigured) {
            try await bootstrap(customBrewPath: customBrewPath)
        }
        let (path, shellenv) = try await resolver.resolvedState()
        var env = ProcessInfo.processInfo.environment
        env.merge(shellenv) { _, new in new }
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        // `HOMEBREW_NO_ASK` is the real switch for brew's "Would install ... proceed? [y/n]"
        // prompt (`Homebrew::Ask.confirm?`) — `HOMEBREW_NO_INTERACTIVE`, which every call site
        // here used to set instead, isn't a Homebrew env var at all, so it silently did nothing.
        // That prompt already skips itself without a TTY, so this alone wasn't the freeze, but
        // there's no case where this app wants brew waiting on stdin it never provides, so it's
        // set unconditionally here rather than per-call-site.
        env["HOMEBREW_NO_ASK"] = "1"
        // `runStreaming` gives `brew` a pty for stdout (see `ProcessRunner`) so curl
        // keeps its download progress instead of going `--silent` — but that also
        // makes `$stdout.tty?` true for brew's *own* colored `ohai`/`opoo` output
        // (`Tty#color?` checks exactly that), which otherwise means raw `\e[32m`-style
        // escape codes end up as literal text in a log view that doesn't interpret
        // them. `HOMEBREW_NO_COLOR` overrides the tty check unconditionally.
        env["HOMEBREW_NO_COLOR"] = "1"
        env["SUDO_ASKPASS"] = Self.askpassPath
        return (path, env)
    }

    /// Path to a helper script that prompts for the admin password via a native macOS
    /// dialog (`osascript`) and prints it to stdout — the contract `SUDO_ASKPASS` expects.
    ///
    /// Some casks (Temurin, Docker, ...) need real root during install/upgrade — e.g.
    /// Temurin's postflight runs `sudo installer` to symlink into `/Library/Java` — and
    /// Homebrew's own `sudo` wrapper reads `SUDO_ASKPASS` and adds `sudo -A` automatically
    /// whenever it's set, so this is enough to get a graphical prompt instead of `sudo`
    /// failing outright for lack of a TTY. Written fresh on every launch (cheap, avoids
    /// version skew) rather than bundled as a resource — it's a few lines of shell.
    private static let askpassPath: String = {
        let dir = FileManager.brewMenuCachesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("askpass.sh")
        let message = L("BrewMenu needs your admin password to complete this Homebrew operation.")
        let cancel = L("Cancel")
        let ok = L("OK")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.brewmenu.app"
        let script = """
        #!/bin/sh
        osascript -e 'text returned of (display dialog "\(
            message
        )" with title "BrewMenu" with icon caution default answer "" with hidden answer buttons {"\(cancel)", "\(
            ok
        )"} default button "\(ok)")'
        # `osascript`'s dialog runs as its own foreground process — once it closes, macOS
        # doesn't reliably hand focus back to BrewMenu (an accessory/menu-bar-only app),
        # leaving the Dashboard buried behind whatever else is on screen. Backgrounded and
        # silenced so it never delays sudo's read of the password line above.
        open -b \(bundleID) >/dev/null 2>&1 &
        """
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }()

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
                case "KB", "KIB": return Int64(value * 1024)
                case "B": return Int64(value)
                default: continue
                }
            }
        }
        return 0
    }

    /// Lines `parseInstalledCasks` drops: non-empty, with fewer than two fields. Recorded by the
    /// caller, so a changed brew output format is visible in the log instead of silently empty.
    static func malformedCaskLines(_ output: String) -> [String] {
        output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && line.components(separatedBy: .whitespaces).count(where: { !$0.isEmpty }) < 2
            }
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
            let key = String(trimmed[trimmed.startIndex ..< eqIndex])
            var value = String(trimmed[trimmed.index(after: eqIndex)...])
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            env[key] = value
        }
        return env
    }
}

/// Collects per-package sizes from the disk-usage worker operations.
private final class DiskUsageResults: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PackageDiskUsage] = []

    func add(_ usage: PackageDiskUsage) {
        lock.withLock { items.append(usage) }
    }

    /// Biggest first — that's what matters for "what should I remove to free space".
    func sorted() -> [PackageDiskUsage] {
        lock.withLock { items.sorted { $0.sizeBytes > $1.sizeBytes } }
    }
}
