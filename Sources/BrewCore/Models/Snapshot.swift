import Foundation

public struct Snapshot: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let outdatedPackages: [OutdatedPackage]
    public let doctorWarnings: [DoctorWarning]
    public let services: [ServiceEntry]
    public let installedCasks: [CaskEntry]
    public let cleanupBytesReclaimable: Int64
    /// Formulae `brew autoremove` would uninstall (dependency-only, nothing needs
    /// them anymore) — see `InsightEngine.unusedDependencies`.
    public let autoremovableFormulae: [String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        outdatedPackages: [OutdatedPackage],
        doctorWarnings: [DoctorWarning],
        services: [ServiceEntry] = [],
        installedCasks: [CaskEntry] = [],
        cleanupBytesReclaimable: Int64 = 0,
        autoremovableFormulae: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.outdatedPackages = outdatedPackages
        self.doctorWarnings = doctorWarnings
        self.services = services
        self.installedCasks = installedCasks
        self.cleanupBytesReclaimable = cleanupBytesReclaimable
        self.autoremovableFormulae = autoremovableFormulae
    }

    /// Custom decoder so old snapshots (missing newer fields) still load with sane defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        outdatedPackages = try c.decode([OutdatedPackage].self, forKey: .outdatedPackages)
        doctorWarnings = try c.decode([DoctorWarning].self, forKey: .doctorWarnings)
        services = try c.decodeIfPresent([ServiceEntry].self, forKey: .services) ?? []
        installedCasks = try c.decodeIfPresent([CaskEntry].self, forKey: .installedCasks) ?? []
        cleanupBytesReclaimable = try c.decodeIfPresent(Int64.self, forKey: .cleanupBytesReclaimable) ?? 0
        autoremovableFormulae = try c.decodeIfPresent([String].self, forKey: .autoremovableFormulae) ?? []
    }
}
