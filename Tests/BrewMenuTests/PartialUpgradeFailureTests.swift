import BrewCore
@testable import BrewMenu
import Foundation
import Testing

/// An Upgrade All that brew finished for every package but one or two: it says which, and why,
/// instead of "Upgrade All failed" — and a retry is about those.
@MainActor
@Suite("Upgrade All con algunos paquetes fallidos", .serialized)
struct PartialUpgradeFailureTests {
    /// brew's stderr from a real run (22 of 23 upgraded): antigravity-cli's `agy` had been replaced
    /// by the tool's own updater, so brew wouldn't put its new wrapper there.
    static let stderr = """
    Warning: Reverting upgrade for Cask antigravity-cli
    Warning: Rolling back the failed upgrade of antigravity-cli also failed: Cask::CaskError: It seems there is already a Binary at '/opt/homebrew/bin/agy'.
    Warning: Temporary files retained at:
    /private/tmp/cask-antigravity-cli-20261122-82462-xl7goq
    Error: antigravity-cli: It seems there is already a Command Wrapper at '/opt/homebrew/bin/agy'.
    """

    @Test("brew dice qué paquete falló y por qué; lo demás no es de un paquete")
    func failedUpgradesFromRealOutput() {
        let failed = BrewError.failedUpgrades(
            in: Self.stderr,
            targets: ["gh", "antigravity-cli", "cameroncooke/axe/axe"]
        )
        #expect(failed.map(\.name) == ["antigravity-cli"])
        #expect(failed.first?.reason == "It seems there is already a Command Wrapper at '/opt/homebrew/bin/agy'.")

        // A tap-qualified target matches brew's bare name, and an error that isn't one package's
        // ("Error: Cannot install…") names none.
        let other = "Error: axe: Failed to download\nError: Cannot install foo because bar"
        #expect(BrewError.failedUpgrades(in: other, targets: ["cameroncooke/axe/axe", "foo"]).map(\.name)
            == ["cameroncooke/axe/axe"])
    }

    @Test("las pistas nuevas: un archivo ajeno en el camino, y un tap que Homebrew no carga sin confianza")
    func newHints() {
        let conflict = BrewError.friendlyHint(for: Self.stderr)
        #expect(conflict ==
            L(
                "Something else is already at \("/opt/homebrew/bin/agy"), and Homebrew won't replace it. Move it out of the way, then try again."
            ))

        let untrusted = "Error: Refusing to load cask productdevbook/tap/fil from untrusted tap productdevbook/tap.\nRun `brew trust --cask productdevbook/tap/fil` or `brew trust productdevbook/tap` to trust it."
        #expect(BrewError.untrustedTap(in: untrusted) == "productdevbook/tap")
        #expect(BrewError.friendlyHint(for: untrusted)?.contains("brew trust productdevbook/tap") == true)

        // An app in Applications keeps its own, more precise hint.
        let app = "Error: It seems there is already an App at '/Applications/Foo.app'."
        #expect(BrewError.friendlyHint(for: app)?.contains("/Applications/Foo.app") == false)
    }

    @Test("el pie, la hoja y la fila hablan del que falló; reintentar es solo ese")
    func partialFailure() async throws {
        let service = MockBrewService()
        let outdated = ["gh", "antigravity-cli", "jq"].map {
            OutdatedPackage(name: $0, installedVersions: ["1.0"], currentVersion: "2.0", pinned: false)
        }
        await service.setFetchResponses([outdated, [outdated[1]]])
        await service.setUpgradeError(BrewError.commandFailed(
            exitCode: 1,
            stderr: Self.stderr,
            command: "brew upgrade gh antigravity-cli jq"
        ))
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        await vm.performUpgradeAll()

        #expect(vm.upgradeFailedPackages == ["antigravity-cli"])
        let hint =
            L(
                "Something else is already at \("/opt/homebrew/bin/agy"), and Homebrew won't replace it. Move it out of the way, then try again."
            )
        #expect(vm.upgradeFailure == "\(L("\(2) upgraded")) · \(hint)")
        guard case let .failed(targets, wasAll, _) = vm.upgradeActivity(at: .now) else {
            Issue.record("expected a failure")
            return
        }
        #expect(targets == ["antigravity-cli"] && !wasAll)
        let banner = UpgradeActivityBanner(
            activity: vm.upgradeActivity(at: .now),
            onShowLog: {},
            onCancel: {},
            onRetry: {},
            onDismiss: {}
        )
        #expect(banner.title == L("Couldn't upgrade \("antigravity-cli")"))
        #expect(vm.upgradeFailure(forPackage: "antigravity-cli") == hint)
        #expect(vm.upgradeFailure(forPackage: "gh") == nil)

        await service.setUpgradeError(nil)
        #expect(vm.retryUpgrade())
        try await waitUntil { !vm.isRunningAnyUpgrade }
        #expect(vm.upgradeTargets == ["antigravity-cli"], "only the one that failed")
        #expect(vm.upgradeFailedPackages.isEmpty)
    }
}
