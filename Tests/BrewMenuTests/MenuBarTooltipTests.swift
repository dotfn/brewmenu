import BrewCore
@testable import BrewMenu
import Foundation
import Testing

@Suite("Menu bar tooltip")
struct MenuBarTooltipTests {
    @Test("sin revisión previa dice que aún no se ha revisado")
    func neverChecked() {
        #expect(MenuBarIconLabel.checkedTooltip(lastChecked: nil) == L("Not checked yet"))
    }

    @Test("con revisión incluye un tiempo relativo")
    func checkedRelative() {
        let now = Date()
        let text = MenuBarIconLabel.checkedTooltip(lastChecked: now.addingTimeInterval(-300), now: now)
        #expect(text != L("Not checked yet"))
        #expect(text.contains("5") || text.contains("minute") || text.contains("minuto"))
    }
}
