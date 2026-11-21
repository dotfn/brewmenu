import AppKit
import BrewCore

/// What the app says about itself — its icon, version, maker and links — in one place, for the
/// About panel and the About section in Settings alike.
enum AppInfo {
    static let name = "BrewMenu"
    static let developerName = "Nicolas Jimenez"
    static let developerURL = URL(string: "https://github.com/dotfn")!
    /// The developer's brand, written the way the website writes it.
    static let brand = "●fn"
    /// How VoiceOver should say `brand`: it reads the glyph as "black circle".
    static let brandSpoken = "dotfn"
    static let brandURL = URL(string: "https://dotfn.dev")!
    static let websiteURL = URL(string: "https://brewmenu.vercel.app/")!
    static let repositoryURL = URL(string: "https://github.com/dotfn/brewmenu")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The build number, when there's a bundle to carry one.
    static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2026 \(brand)"
    }

    /// The app's real icon. Loaded from AppIcon.icns via AppBundle (the resolver Localizable.strings
    /// and InstallPacks.json use) instead of NSApp.applicationIconImage, which is the generic folder
    /// icon when running unpackaged (`swift build`/Xcode's SPM scheme): with no .app bundle, macOS
    /// has no CFBundleIconFile to resolve.
    @MainActor
    static var icon: NSImage {
        if let url = AppBundle.resources.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        // `NSApplication.shared`, not `NSApp`: that one is nil until something creates the app.
        return NSApplication.shared.applicationIconImage
    }
}

/// The standard About panel, filled in by the app instead of left to the bundle. Left to the bundle
/// it showed a folder icon and no version when running unpackaged, and never said who made it.
@MainActor
enum AboutPanel {
    static func show() {
        // A menu-bar app isn't frontmost: without this the panel opens behind the window in front.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    static var options: [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationIcon: AppInfo.icon,
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): AppInfo.copyright,
        ]
        // An empty build number would still draw "()" after the version.
        if let build = AppInfo.build, !build.isEmpty { options[.version] = build }
        return options
    }

    /// "Homebrew health monitor for macOS", then who made it and where to find more — the links
    /// clickable, the rest in the panel's own small secondary text.
    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        func text(_ string: String) -> NSAttributedString {
            NSAttributedString(string: string, attributes: base)
        }
        func link(_ string: String, _ url: URL) -> NSAttributedString {
            var attributes = base
            attributes[.link] = url
            return NSAttributedString(string: string, attributes: attributes)
        }

        let credits = NSMutableAttributedString()
        credits.append(text(L("Homebrew health monitor for macOS") + "\n"))
        credits.append(text(L("Developed by") + " "))
        credits.append(link(AppInfo.developerName, AppInfo.developerURL))
        credits.append(text(" · "))
        credits.append(link(AppInfo.brand, AppInfo.brandURL))
        credits.append(text("\n"))
        credits.append(link(AppInfo.websiteURL.host() ?? AppInfo.websiteURL.absoluteString, AppInfo.websiteURL))
        credits.append(text(" · "))
        credits.append(link(L("Source code"), AppInfo.repositoryURL))
        return credits
    }
}
