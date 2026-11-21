import AppKit
import BrewCore
@testable import BrewMenu
import SwiftUI
import Testing

/// The popover's upgrade footer, mounted in-process (see `HostedView`): each state says what's
/// going on, and offers only what makes sense then.
@MainActor
@Suite("UpgradeActivityBanner montado", .serialized)
struct UpgradeActivityBannerTests {
    private func labels(for activity: UpgradeActivity) async throws -> [String] {
        let banner = UpgradeActivityBanner(
            activity: activity, onShowLog: {}, onCancel: {}, onRetry: {}, onDismiss: {}
        )
        let hosted = HostedView(banner, size: CGSize(width: 360, height: 120))
        defer { hosted.close() }
        try await hosted.settle()
        return hosted.labels
    }

    private func banner(_ activity: UpgradeActivity) -> UpgradeActivityBanner {
        UpgradeActivityBanner(activity: activity, onShowLog: {}, onCancel: {}, onRetry: {}, onDismiss: {})
    }

    @Test("en marcha: qué paquete, la fase y el tiempo; se puede ver el log o cancelar")
    func running() async throws {
        let activity = UpgradeActivity.running(
            targets: ["gh"], step: .downloading, progress: 0.4, elapsed: 42, quietFor: nil
        )
        let labels = try await labels(for: activity)
        #expect(labels.contains(L("Upgrading \("gh")")), "labels: \(labels)")
        // brew's own percentage, when it gives one.
        let percent = 0.4.formatted(.percent.precision(.fractionLength(0)))
        #expect(labels.contains("\(L("Downloading…")) \(percent) · 0:42"), "labels: \(labels)")
        #expect(labels.contains(L("Show Log")) && labels.contains(L("Cancel")), "labels: \(labels)")
        #expect(!labels.contains(L("Retry")), "labels: \(labels)")
        // One line while things go normally: no second line to read.
        #expect(banner(activity).detail == nil)
        // A step that says nothing the spinner doesn't leaves just the time.
        let working = UpgradeActivity.running(targets: ["gh"], step: .working, progress: nil, elapsed: 5, quietFor: nil)
        #expect(banner(working).note == "0:05")
    }

    @Test("sin salida un minuto: lo dice en la misma línea, con la frase entera en el tooltip")
    func quiet() {
        let activity = UpgradeActivity.running(
            targets: ["gh"], step: .working, progress: 0.9, elapsed: 200, quietFor: 75
        )
        let minute = Duration.seconds(60).formatted(.units(allowed: [.minutes], width: .wide))
        #expect(banner(activity).note == L("No output for \(minute)"))
        #expect(banner(activity).explanation == L("No output for \(minute). Homebrew may be stuck."))
        #expect(banner(activity).detail == nil, "no second line: the footer keeps its height")
    }

    @Test("el pie mide lo mismo en marcha, en cola, colgado, cancelando, cancelado y terminado")
    func oneHeightForEveryOneLineState() {
        func height(_ activity: UpgradeActivity) -> CGFloat {
            NSHostingView(rootView: banner(activity).frame(width: 360)).fittingSize.height
        }
        let oneLine: [UpgradeActivity] = [
            .running(targets: ["warp"], step: .downloading, progress: nil, elapsed: 3, quietFor: nil),
            .running(targets: ["warp"], step: .working, progress: nil, elapsed: 90, quietFor: 70),
            .waiting(targets: ["warp"]),
            .cancelling(targets: ["warp"]),
            .cancelled(targets: ["warp"]),
            .done(targets: ["warp"]),
        ]
        let heights = oneLine.map(height)
        #expect(Set(heights).count == 1, "heights: \(heights)")
        // The idle footer is the same line height plus the same padding (MenuBarView.idleFooter).
        #expect(heights.first == UpgradeActivityBanner.lineHeight + 16)
        // Only a failure grows, for its reason.
        #expect(height(.failed(targets: ["warp"], wasAll: false, reason: "Error: nope")) > heights[0])
    }

    @Test("fallido: el motivo, y ver el log, reintentar o descartar")
    func failed() async throws {
        let labels = try await labels(for: .failed(targets: ["gh"], wasAll: false, reason: "Error: nope"))
        #expect(labels.contains(L("Couldn't upgrade \("gh")")), "labels: \(labels)")
        #expect(labels.contains("Error: nope"), "labels: \(labels)")
        for action in [L("Show Log"), L("Retry"), L("Dismiss")] {
            #expect(labels.contains(action), "missing \(action) — labels: \(labels)")
        }
        #expect(!labels.contains(L("Cancel")), "labels: \(labels)")
    }

    @Test("Upgrade All dice cuántos, y su fallo no culpa a un paquete")
    func upgradeAllWording() {
        let all = ["a", "b", "c"]
        #expect(banner(.running(targets: all, step: .working, progress: nil, elapsed: 1, quietFor: nil)).title
            == L("Upgrading \(3) packages"))
        #expect(banner(.done(targets: all)).title == L("\(L("\(3) packages")) upgraded"))
        #expect(banner(.failed(targets: all, wasAll: true, reason: "x")).title == L("Upgrade All failed"))
    }

    @Test("Upgrade All en marcha: el paquete en curso en el título, y cuántos lleva junto al tiempo")
    func upgradeAllPosition() {
        let activity = UpgradeActivity.running(
            targets: ["gh", "jq", "wget"], step: .downloading, progress: nil, elapsed: 62, quietFor: nil,
            position: UpgradeActivity.Position(current: "jq", number: 2, total: 3)
        )
        #expect(banner(activity).title == L("Upgrading \("jq")"))
        #expect(banner(activity).note == "\(L("\(2) of \(3)")) · \(L("Downloading…")) 1:02")
    }

    @Test("descargando con bytes reales: los dice junto a la fase")
    func downloadedBytes() {
        let activity = UpgradeActivity.running(
            targets: ["gh"], step: .downloading, progress: nil, elapsed: 42, quietFor: nil,
            downloaded: 23_400_000
        )
        let bytes = ByteCountFormatter.string(fromByteCount: 23_400_000, countStyle: .file)
        #expect(banner(activity).note == "\(L("Downloading…")) \(bytes) · 0:42")
        // A real percentage from brew wins over the bytes counted from outside.
        let withPercent = UpgradeActivity.running(
            targets: ["gh"], step: .downloading, progress: 0.46, elapsed: 42, quietFor: nil,
            downloaded: 23_400_000
        )
        let percent = 0.46.formatted(.percent.precision(.fractionLength(0)))
        #expect(banner(withPercent).note == "\(L("Downloading…")) \(percent) · 0:42")
        // Bytes belong to downloading; another step doesn't show them.
        let installing = UpgradeActivity.running(
            targets: ["gh"], step: .installing, progress: nil, elapsed: 42, quietFor: nil, downloaded: 23_400_000
        )
        #expect(banner(installing).note == "\(L("Installing…")) 0:42")
    }

    @Test("en cola detrás de otro comando: lo explica y deja cancelar")
    func waiting() async throws {
        let labels = try await labels(for: .waiting(targets: ["gh"]))
        #expect(labels.contains(L("Waiting for Homebrew")), "labels: \(labels)")
        #expect(labels.contains(L("Cancel")), "labels: \(labels)")
    }
}
