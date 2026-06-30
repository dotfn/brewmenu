import Foundation

struct Snapshot: Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let outdatedPackages: [OutdatedPackage]
    let doctorWarnings: [DoctorWarning]
    let services: [ServiceEntry]
    let installedCasks: [CaskEntry]
    let cleanupBytesReclaimable: Int64

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        outdatedPackages: [OutdatedPackage],
        doctorWarnings: [DoctorWarning],
        services: [ServiceEntry] = [],
        installedCasks: [CaskEntry] = [],
        cleanupBytesReclaimable: Int64 = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.outdatedPackages = outdatedPackages
        self.doctorWarnings = doctorWarnings
        self.services = services
        self.installedCasks = installedCasks
        self.cleanupBytesReclaimable = cleanupBytesReclaimable
    }

    // Custom decoder so old snapshots (missing newer fields) still load with sane defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        outdatedPackages = try c.decode([OutdatedPackage].self, forKey: .outdatedPackages)
        doctorWarnings = try c.decode([DoctorWarning].self, forKey: .doctorWarnings)
        services = try c.decodeIfPresent([ServiceEntry].self, forKey: .services) ?? []
        installedCasks = try c.decodeIfPresent([CaskEntry].self, forKey: .installedCasks) ?? []
        cleanupBytesReclaimable = try c.decodeIfPresent(Int64.self, forKey: .cleanupBytesReclaimable) ?? 0
    }
}
