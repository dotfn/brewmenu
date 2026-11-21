import AppKit
import BrewCore
@testable import BrewMenu
import Foundation
import Testing

/// The About panel's contents come from the app, not the bundle — so they're there when running
/// unpackaged too (Xcode, `swift run`), which showed a folder icon and no version.
@MainActor
@Suite("AboutPanel")
struct AboutPanelTests {
    @Test("el panel lleva icono, nombre, versión y copyright con la marca")
    func panelHasItsBasics() throws {
        let options = AboutPanel.options
        #expect(options[.applicationIcon] is NSImage)
        #expect(options[.applicationName] as? String == "BrewMenu")
        #expect(options[.applicationVersion] as? String == AppInfo.version)
        let copyright = try #require(options[NSApplication.AboutPanelOptionKey(rawValue: "Copyright")] as? String)
        #expect(copyright.contains("●fn"))
    }

    @Test("los créditos dicen quién la hizo, y cada enlace lleva a su sitio")
    func creditsLinkTheirSites() {
        let credits = AboutPanel.credits
        #expect(credits.string.contains(L("Homebrew health monitor for macOS")))
        #expect(credits.string.contains("Nicolas Jimenez · ●fn"))

        var links: [String: String] = [:]
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            links[(credits.string as NSString).substring(with: range)] = url.absoluteString
        }
        #expect(links == [
            "Nicolas Jimenez": "https://github.com/dotfn",
            "●fn": "https://dotfn.dev",
            "brewmenu.vercel.app": "https://brewmenu.vercel.app/",
            L("Source code"): "https://github.com/dotfn/brewmenu",
        ])
    }
}
