import BrewCore
@testable import BrewMenu
import Foundation
import Testing

@Suite("BrewMenuDataRoots")
struct DataRootsTests {
    // Regression: the app had no way to run away from the real folders, so a verification run
    // wrote into the user's own BrewMenu data. With the override, every root sits under one folder.
    @Test("con override, todo cuelga de esa carpeta")
    func overrideKeepsEverythingUnderOneFolder() {
        let base = URL(fileURLWithPath: "/tmp/isolated-brewmenu", isDirectory: true)
        let roots = BrewMenuDataRoots.resolve(override: base)
        #expect(roots.support.path == "/tmp/isolated-brewmenu/support")
        #expect(roots.caches.path == "/tmp/isolated-brewmenu/caches")
        #expect(roots.logs.path == "/tmp/isolated-brewmenu/logs")
    }

    @Test("sin override, usa las rutas de macOS")
    func withoutOverrideUsesMacOSLocations() {
        let roots = BrewMenuDataRoots.resolve(override: nil)
        #expect(roots.support.path.hasSuffix("Library/Application Support/BrewMenu"))
        #expect(roots.caches.path.hasSuffix("Library/Caches/BrewMenu"))
        #expect(roots.logs.path.hasSuffix("Library/Logs/BrewMenu"))
    }

    // Regression: a test run used the real folders, and the "Reset all data" test deleted the
    // user's settings.json, caches and log every time the suite ran.
    @Test("una ejecución de tests nunca usa las carpetas reales del usuario")
    func suiteNeverTouchesTheRealFolders() {
        let real = BrewMenuDataRoots.resolve(override: nil)

        #expect(BrewMenuDataRoots.environmentOverride != nil)
        #expect(FileManager.brewMenuSupportDirectory != real.support)
        #expect(FileManager.brewMenuCachesDirectory != real.caches)
        #expect(FileManager.brewMenuLogsDirectory != real.logs)
    }
}
