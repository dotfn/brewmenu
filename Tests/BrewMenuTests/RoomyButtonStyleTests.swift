import AppKit
@testable import BrewMenu
import SwiftUI
import Testing

/// `RoomyButtonStyle` re-creates the button inside its style; what's set on the outer button has to
/// reach that inner one — the shortcut, disabled, the label VoiceOver reads.
@MainActor
@Suite("RoomyButtonStyle", .serialized)
struct RoomyButtonStyleTests {
    @MainActor
    final class Counter {
        var presses = 0
    }

    private func commandR(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15
        ))
    }

    private func mount(disabled: Bool, counter: Counter) -> HostedView {
        HostedView(
            Button("Check Again") { counter.presses += 1 }
                .buttonStyle(.roomyBordered)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(disabled)
                .accessibilityLabel("Run it again"),
            size: CGSize(width: 300, height: 100)
        )
    }

    @Test("el atajo de teclado llega al botón")
    func shortcutReachesTheButton() async throws {
        let counter = Counter()
        let hosted = mount(disabled: false, counter: counter)
        defer { hosted.close() }
        try await hosted.settle()

        #expect(hosted.window.performKeyEquivalent(with: try commandR(in: hosted.window)))
        try await waitUntil { counter.presses == 1 }
    }

    @Test("deshabilitado, ni el atajo ni VoiceOver lo pulsan")
    func disabledStaysDisabled() async throws {
        let counter = Counter()
        let hosted = mount(disabled: true, counter: counter)
        defer { hosted.close() }
        try await hosted.settle()

        _ = hosted.window.performKeyEquivalent(with: try commandR(in: hosted.window))
        hosted.element(labeled: "Run it again")?.press()
        try await hosted.settle()
        #expect(counter.presses == 0)
    }

    @Test("VoiceOver lee la etiqueta del botón de fuera y puede pulsarlo")
    func accessibilityLabelAndPress() async throws {
        let counter = Counter()
        let hosted = mount(disabled: false, counter: counter)
        defer { hosted.close() }
        try await hosted.settle()

        let button = try #require(hosted.element(labeled: "Run it again"), "labels: \(hosted.labels)")
        #expect(button.press())
        try await waitUntil { counter.presses == 1 }
    }
}
