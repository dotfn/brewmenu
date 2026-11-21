import AppKit
import SwiftUI

/// A SwiftUI view mounted in a real, never-shown window, read through its accessibility tree — the
/// same tree VoiceOver and XCUITest see, but in-process: no app launch, no Accessibility permission,
/// so it runs under `swift test`, Xcode's ⌘U and CI alike.
@MainActor
final class HostedView {
    let window: NSWindow

    init(_ view: some View, size: CGSize = CGSize(width: 400, height: 600)) {
        Self.enableAccessibilityTree()
        let hosting = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        window.close()
    }

    /// SwiftUI only builds its accessibility tree once an assistive client asks for it: until then
    /// every hosting view reports no children. Setting `AXEnhancedUserInterface` on the app is how
    /// VoiceOver asks (`AXManualAccessibility` doesn't do it — tried on macOS 27).
    private static var accessibilityEnabled = false
    private static func enableAccessibilityTree() {
        guard !accessibilityEnabled else { return }
        accessibilityEnabled = true
        _ = NSApplication.shared.perform(
            Selector(("accessibilitySetValue:forAttribute:")),
            with: NSNumber(value: true),
            with: "AXEnhancedUserInterface"
        )
    }

    /// Every accessibility element under the window's content, depth first.
    ///
    /// SwiftUI's elements answer the NSAccessibility messages but don't formally conform to the
    /// Swift protocol, so a cast to it fails: they're read as plain objects instead.
    var elements: [HostedElement] {
        var found: [HostedElement] = []
        func visit(_ object: NSObject) {
            found.append(HostedElement(object: object))
            let children = object.value(forKey: "accessibilityChildren") as? [NSObject] ?? []
            children.forEach(visit)
        }
        if let content = window.contentView { visit(content) }
        return found
    }

    /// The text of everything on screen — what a failing test should print.
    var labels: [String] {
        elements.compactMap { $0.label ?? $0.value }
    }

    func element(labeled label: String) -> HostedElement? {
        elements.first { $0.label == label }
    }

    /// Lets SwiftUI apply pending state changes and lay out again.
    ///
    /// Sleeps instead of spinning `RunLoop.main`: a spin inside a main-actor test holds the main
    /// actor the whole time, starving every other suite that's waiting on it in the same run.
    func settle(_ duration: Duration = .milliseconds(100)) async throws {
        try await Task.sleep(for: duration)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}

/// One node of a `HostedView`'s accessibility tree.
@MainActor
struct HostedElement {
    let object: NSObject

    var role: String? {
        object.value(forKey: "accessibilityRole") as? String
    }

    /// What VoiceOver reads: the text a `Button` or `.accessibilityLabel(_:)` gives it.
    var label: String? {
        (object.value(forKey: "accessibilityLabel") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A `Text`'s string lives here, not in `label`.
    var value: String? {
        (object.value(forKey: "accessibilityValue") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var identifier: String? {
        object.value(forKey: "accessibilityIdentifier") as? String
    }

    var isEnabled: Bool {
        object.value(forKey: "accessibilityEnabled") as? Bool ?? true
    }

    /// Clicks it, the way VoiceOver's "press" does.
    @discardableResult
    func press() -> Bool {
        object.perform(Selector(("accessibilityPerformPress"))) != nil
    }
}
