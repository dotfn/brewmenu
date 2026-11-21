import Darwin
import Foundation

/// What brew is doing that its printed output doesn't say. Brew draws its download progress only
/// on a terminal (`download_queue.rb`), and BrewMenu reads it through a pipe — so this looks from
/// the outside instead: Homebrew's in-progress downloads on disk, and the CPU of the processes this
/// app has started (brew, and what brew runs).
struct BrewActivitySample: Equatable {
    /// Written to Homebrew's in-progress downloads since the run started. Each file counts at the
    /// largest size it was seen at, so a finished download (renamed, no longer `.incomplete`)
    /// doesn't take its bytes away.
    var downloadedBytes: Int64
    /// CPU time used so far by every process under this app.
    var cpuTime: TimeInterval
    /// What the busiest of them was doing since the last sample, told by its name.
    var busyWith: BrewBusyWith?
    /// Written to Homebrew's build logs since the run started. A build from source prints little
    /// for minutes while its log keeps growing.
    var buildLogBytes: Int64 = 0
}

/// A process brew runs, by what it's for.
enum BrewBusyWith: Equatable {
    case downloading, unpacking, compiling, installing

    /// From a process name — the tools Homebrew runs for each step.
    init?(processName name: String) {
        switch name {
        case "curl":
            self = .downloading
        case "tar", "bsdtar", "gtar", "unzip", "xz", "zstd", "gzip", "bzip2", "hdiutil":
            self = .unpacking
        case "clang", "clang++", "cc", "c++", "ld", "make", "gmake", "cmake", "ninja", "cargo", "rustc",
             "go", "swift-frontend", "swift-build", "meson", "autoconf", "automake", "configure":
            self = .compiling
        case "installer", "pkgutil", "ditto":
            self = .installing
        default:
            return nil
        }
    }
}

protocol BrewActivitySampling: Sendable {
    /// Forgets the last run and starts counting from `date`.
    func start(at date: Date) async
    func sample() async -> BrewActivitySample
}

/// Reads the real disk and process table. Only this app's own descendants are looked at, which
/// needs no permission.
actor LiveBrewActivityProbe: BrewActivitySampling {
    private let downloadsDirectory: URL
    private let logsDirectory: URL
    private var startedAt = Date.distantPast
    /// Largest size seen per in-progress download this run, by path.
    private var downloadSizes: [String: Int64] = [:]
    /// CPU time per process at the last sample, to tell which one is busy now.
    private var lastCPUTime: [pid_t: TimeInterval] = [:]

    /// `$HOMEBREW_CACHE/downloads` and `$HOMEBREW_LOGS`, Homebrew's defaults otherwise.
    init(downloadsDirectory: URL? = nil, logsDirectory: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cache = environment["HOMEBREW_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Caches/Homebrew")
        self.downloadsDirectory = downloadsDirectory ?? cache.appendingPathComponent("downloads")
        self.logsDirectory = logsDirectory
            ?? environment["HOMEBREW_LOGS"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Logs/Homebrew")
    }

    func start(at date: Date) {
        startedAt = date
        downloadSizes = [:]
        lastCPUTime = [:]
    }

    func sample() -> BrewActivitySample {
        let processes = Self.descendants(of: getpid())
        var total: TimeInterval = 0
        var busiest: (delta: TimeInterval, busy: BrewBusyWith?)?
        var current: [pid_t: TimeInterval] = [:]
        for pid in processes {
            guard let cpu = Self.cpuTime(of: pid) else { continue }
            current[pid] = cpu
            total += cpu
            let delta = cpu - (lastCPUTime[pid] ?? 0)
            if delta > (busiest?.delta ?? 0) {
                busiest = (delta, Self.name(of: pid).flatMap(BrewBusyWith.init(processName:)))
            }
        }
        lastCPUTime = current
        return BrewActivitySample(
            downloadedBytes: measureDownloads(),
            cpuTime: total,
            busyWith: busiest?.busy,
            buildLogBytes: measureBuildLogs()
        )
    }

    /// One folder per package, one file per build step (`01.configure`, `02.make`…).
    private func measureBuildLogs() -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let packages = (try? FileManager.default.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        var total: Int64 = 0
        for package in packages {
            let files = (try? FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: keys)) ??
                []
            for file in files {
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= startedAt,
                      let size = values.fileSize
                else { continue }
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Downloads

    /// Homebrew writes a download to `<name>.incomplete` and renames it when it's done
    /// (`abstract_file_download_strategy.rb`).
    private func measureDownloads() -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory, includingPropertiesForKeys: Array(keys)
        )) ?? []
        for file in files where file.pathExtension == "incomplete" {
            guard let values = try? file.resourceValues(forKeys: keys),
                  let modified = values.contentModificationDate, modified >= startedAt,
                  let size = values.fileSize
            else { continue }
            downloadSizes[file.path] = max(downloadSizes[file.path] ?? 0, Int64(size))
        }
        return downloadSizes.values.reduce(0, +)
    }

    // MARK: - Processes

    static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue = [root]
        while let pid = queue.popLast() {
            var children = [pid_t](repeating: 0, count: 256)
            let count = children.withUnsafeMutableBytes {
                proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { continue }
            let direct = children.prefix(Int(count)).filter { $0 > 0 }
            found += direct
            queue += direct
        }
        return found
    }

    /// User plus system CPU time, in seconds.
    static func cpuTime(of pid: pid_t) -> TimeInterval? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        // Mach absolute time units, which are nanoseconds only on Intel.
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        return ticks * timebase / 1_000_000_000
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = Int(proc_name(pid, &buffer, UInt32(buffer.count)))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()
}
