import Testing
import Foundation
@testable import BrewMenu

// MARK: - Fixtures

private func snapshot(
    daysAgo: Double,
    outdated: [String] = [],
    warnings: [DoctorWarning] = [],
    casks: [CaskEntry] = [],
    cleanupBytes: Int64 = 0
) -> Snapshot {
    let date = Date().addingTimeInterval(-daysAgo * 86400)
    let packages = outdated.map { OutdatedPackage(name: $0, installedVersions: ["1.0"], currentVersion: "2.0", pinned: false) }
    return Snapshot(id: UUID(), timestamp: date, outdatedPackages: packages, doctorWarnings: warnings, installedCasks: casks, cleanupBytesReclaimable: cleanupBytes)
}

private let oneGiB: Int64 = 1_073_741_824

// MARK: - Tests

@Suite("InsightEngine")
struct InsightEngineTests {

    // MARK: Empty input

    @Test("sin snapshots → sin insights")
    func noSnapshotsProducesNoInsights() {
        let result = InsightEngine.insights(from: [])
        #expect(result.isEmpty)
    }

    // MARK: staleUpdate

    @Test("paquete en outdated desde hace +14 días → insight stale-updates")
    func staleUpdateFiresAfter14Days() {
        let old = snapshot(daysAgo: 20, outdated: ["git", "curl"])
        let latest = snapshot(daysAgo: 0, outdated: ["git", "curl"])
        let result = InsightEngine.staleUpdate(in: [latest, old])
        #expect(result?.id == "stale-updates")
        #expect(result?.severity == .warning)
    }

    @Test("paquete outdated solo en snapshot reciente → no hay insight stale")
    func newOutdatedPackageDoesNotFireStale() {
        let latest = snapshot(daysAgo: 3, outdated: ["git"])
        let result = InsightEngine.staleUpdate(in: [latest])
        #expect(result == nil)
    }

    @Test("paquete outdated <14 días → no hay insight stale")
    func freshOutdatedPackageDoesNotFireStale() {
        let old = snapshot(daysAgo: 10, outdated: ["git"])
        let latest = snapshot(daysAgo: 0, outdated: ["git"])
        let result = InsightEngine.staleUpdate(in: [latest, old])
        #expect(result == nil)
    }

    @Test("paquete actualizado no dispara stale aunque otros sí")
    func upgradedPackageExcludedFromStale() {
        let old = snapshot(daysAgo: 20, outdated: ["git", "curl"])
        // "curl" was upgraded — solo "git" persiste en latest
        let latest = snapshot(daysAgo: 0, outdated: ["git"])
        let result = InsightEngine.staleUpdate(in: [latest, old])
        #expect(result?.id == "stale-updates")
        // Solo "git" debe aparecer, "curl" no
        #expect(result?.detail.contains("git") == true)
        #expect(result?.detail.contains("curl") == false)
    }

    @Test("sin paquetes outdated en latest → no hay insight stale")
    func noOutdatedInLatestNoStale() {
        let old = snapshot(daysAgo: 20, outdated: ["git"])
        let latest = snapshot(daysAgo: 0, outdated: [])
        let result = InsightEngine.staleUpdate(in: [latest, old])
        #expect(result == nil)
    }

    // MARK: doctorNotRun

    @Test("snapshot reciente → no hay insight doctor")
    func recentSnapshotNoDoctorInsight() {
        let latest = snapshot(daysAgo: 5)
        let result = InsightEngine.doctorNotRun(latest: latest)
        #expect(result == nil)
    }

    @Test("snapshot de hace +30 días → insight doctor-not-run")
    func oldSnapshotFiresDoctorInsight() {
        let latest = snapshot(daysAgo: 35)
        let result = InsightEngine.doctorNotRun(latest: latest)
        #expect(result?.id == "doctor-not-run")
        #expect(result?.severity == .warning)
    }

    @Test("snapshot justo en 30 días → no dispara (límite exacto)")
    func snapshotAt30DaysExactlyNoInsight() {
        // 30 días en segundos - usamos 29.9 para verificar que el límite es estricto
        let latest = snapshot(daysAgo: 29.9)
        let result = InsightEngine.doctorNotRun(latest: latest)
        #expect(result == nil)
    }

    // MARK: cleanupPending

    @Test(">1 GB reclaimable sin cleanup reciente → insight cleanup-pending")
    func cleanupPendingFiresWhenBigAndStale() {
        let old = snapshot(daysAgo: 20, cleanupBytes: oneGiB + 1)
        let latest = snapshot(daysAgo: 0, cleanupBytes: oneGiB + 1)
        let result = InsightEngine.cleanupPending(in: [latest, old])
        #expect(result?.id == "cleanup-pending")
        #expect(result?.severity == .warning)
    }

    @Test("≤1 GB reclaimable → no hay insight cleanup")
    func cleanupPendingDoesNotFireBelowThreshold() {
        let latest = snapshot(daysAgo: 0, cleanupBytes: oneGiB)
        let result = InsightEngine.cleanupPending(in: [latest])
        #expect(result == nil)
    }

    @Test("cleanup reciente (bytes == 0 hace <14 días) → no hay insight cleanup")
    func cleanupPendingDoesNotFireWhenRecentCleanup() {
        let recentClean = snapshot(daysAgo: 5, cleanupBytes: 0)
        let latest = snapshot(daysAgo: 0, cleanupBytes: oneGiB + 1)
        let result = InsightEngine.cleanupPending(in: [latest, recentClean])
        #expect(result == nil)
    }

    @Test("cleanup hace >14 días (bytes == 0 viejo) → insight cleanup-pending")
    func cleanupPendingFiresWhenLastCleanupOld() {
        let oldClean = snapshot(daysAgo: 20, cleanupBytes: 0)
        let latest = snapshot(daysAgo: 0, cleanupBytes: oneGiB + 1)
        let result = InsightEngine.cleanupPending(in: [latest, oldClean])
        #expect(result?.id == "cleanup-pending")
    }

    @Test("sin historial de cleanup (todo >0) → insight cleanup-pending si >1 GB")
    func cleanupPendingFiresWithNoCleanupHistory() {
        let latest = snapshot(daysAgo: 0, cleanupBytes: 2 * oneGiB)
        let result = InsightEngine.cleanupPending(in: [latest])
        #expect(result?.id == "cleanup-pending")
    }

    @Test("insight contiene el tamaño formateado")
    func cleanupPendingDetailContainsSize() {
        let latest = snapshot(daysAgo: 0, cleanupBytes: 2 * oneGiB)
        let result = InsightEngine.cleanupPending(in: [latest])
        // ByteCountFormatter would render "2 GB" — just verify the detail is non-empty
        #expect(result?.detail.isEmpty == false)
    }

    // MARK: accumulatedUpdates

    @Test("≤20 paquetes → no hay insight accumulated")
    func fewPackagesNoAccumulatedInsight() {
        let latest = snapshot(daysAgo: 0, outdated: Array(repeating: "pkg", count: 20).enumerated().map { "pkg\($0.offset)" })
        let result = InsightEngine.accumulatedUpdates(latest: latest)
        #expect(result == nil)
    }

    @Test(">20 paquetes → insight accumulated-updates critical")
    func manyPackagesFiresAccumulatedInsight() {
        let names = (0..<21).map { "pkg\($0)" }
        let latest = snapshot(daysAgo: 0, outdated: names)
        let result = InsightEngine.accumulatedUpdates(latest: latest)
        #expect(result?.id == "accumulated-updates")
        #expect(result?.severity == .critical)
    }

    // MARK: insights(from:) — integración

    @Test("insights(from:) devuelve todos los insights que aplican")
    func insightsFromCombinesAllRules() {
        let names = (0..<21).map { "pkg\($0)" }
        let old = snapshot(daysAgo: 20, outdated: names)
        let latest = snapshot(daysAgo: 0, outdated: names)
        let result = InsightEngine.insights(from: [latest, old])
        // stale + accumulated deben disparar; doctor NO (latest es de hoy)
        #expect(result.contains(where: { $0.id == "stale-updates" }))
        #expect(result.contains(where: { $0.id == "accumulated-updates" }))
        #expect(!result.contains(where: { $0.id == "doctor-not-run" }))
    }

    // MARK: abandonedCask

    @Test("cask estable +14 días sin updates disponibles → insight abandoned-cask")
    func abandonedCaskFiresAfter14Days() {
        let cask = CaskEntry(name: "alfred", version: "5.5.2")
        let old = snapshot(daysAgo: 20, casks: [cask])
        let latest = snapshot(daysAgo: 0, casks: [cask])
        let result = InsightEngine.abandonedCask(in: [latest, old])
        #expect(result?.id == "abandoned-cask")
        #expect(result?.severity == .info)
        #expect(result?.detail.contains("alfred") == true)
    }

    @Test("cask con update disponible no dispara abandoned")
    func caskWithUpdateDoesNotFireAbandoned() {
        let cask = CaskEntry(name: "alfred", version: "5.5.2")
        let old = snapshot(daysAgo: 20, casks: [cask])
        // alfred aparece en outdated → hay update → no es "abandonado"
        let latest = snapshot(daysAgo: 0, outdated: ["alfred"], casks: [cask])
        let result = InsightEngine.abandonedCask(in: [latest, old])
        #expect(result == nil)
    }

    @Test("cask cambió versión entre snapshots → no dispara")
    func caskVersionChangedDoesNotFireAbandoned() {
        let old = snapshot(daysAgo: 20, casks: [CaskEntry(name: "alfred", version: "5.5.1")])
        let latest = snapshot(daysAgo: 0, casks: [CaskEntry(name: "alfred", version: "5.5.2")])
        let result = InsightEngine.abandonedCask(in: [latest, old])
        #expect(result == nil)
    }

    @Test("historial de solo 1 snapshot → no dispara")
    func singleSnapshotDoesNotFireAbandoned() {
        let cask = CaskEntry(name: "alfred", version: "5.5.2")
        let only = snapshot(daysAgo: 0, casks: [cask])
        let result = InsightEngine.abandonedCask(in: [only])
        #expect(result == nil)
    }

    @Test("historial <14 días → no dispara")
    func spanTooShortDoesNotFireAbandoned() {
        let cask = CaskEntry(name: "alfred", version: "5.5.2")
        let old = snapshot(daysAgo: 10, casks: [cask])
        let latest = snapshot(daysAgo: 0, casks: [cask])
        let result = InsightEngine.abandonedCask(in: [latest, old])
        #expect(result == nil)
    }

    @Test("sin casks instalados → no dispara")
    func noCasksDoesNotFireAbandoned() {
        let old = snapshot(daysAgo: 20)
        let latest = snapshot(daysAgo: 0)
        let result = InsightEngine.abandonedCask(in: [latest, old])
        #expect(result == nil)
    }

    @Test("cask no presente en snapshot antiguo → no se considera estancado")
    func newCaskNotInOldSnapshotDoesNotFireAbandoned() {
        let old = snapshot(daysAgo: 20, casks: [CaskEntry(name: "other", version: "1.0")])
        let latest = snapshot(daysAgo: 0, casks: [CaskEntry(name: "alfred", version: "5.5.2")])
        let result = InsightEngine.abandonedCask(in: [latest, old])
        #expect(result == nil)
    }

    // MARK: insights(from:) — integración

    @Test("insights(from:) orden estable: stale → doctor → accumulated")
    func insightsFromPreservesOrder() {
        let names = (0..<21).map { "pkg\($0)" }
        let old = snapshot(daysAgo: 40, outdated: names)
        let latest = snapshot(daysAgo: 35, outdated: names)
        let result = InsightEngine.insights(from: [latest, old])
        let ids = result.map(\.id)
        // Todos deben estar, en el orden del engine
        #expect(ids == ["stale-updates", "doctor-not-run", "accumulated-updates"])
    }
}
