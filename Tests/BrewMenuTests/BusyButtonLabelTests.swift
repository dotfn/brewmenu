import AppKit
@testable import BrewMenu
import SwiftUI
import Testing

@MainActor
@Suite("BusyButtonLabel")
struct BusyButtonLabelTests {
    private func buttonSize(isBusy: Bool, busyTitle: String) -> CGSize {
        let button = Button {} label: {
            BusyButtonLabel(title: "Check Again", busyTitle: busyTitle, systemImage: "arrow.clockwise", isBusy: isBusy)
        }
        .buttonStyle(.roomyBordered)
        return NSHostingView(rootView: button).fittingSize
    }

    @Test(
        "el botón mide lo mismo en reposo y en marcha: nada se mueve cuando empieza o termina",
        arguments: ["Checking…", "Comprobando…", "…"]
    )
    func sameSizeInBothStates(busyTitle: String) {
        let idle = buttonSize(isBusy: false, busyTitle: busyTitle)
        let busy = buttonSize(isBusy: true, busyTitle: busyTitle)
        #expect(idle == busy)
        #expect(idle.width > 0)
    }

    @Test("VoiceOver solo encuentra el estado que se ve")
    func onlyTheVisibleStateIsRead() async throws {
        for isBusy in [false, true] {
            let hosted = HostedView(
                BusyButtonLabel(
                    title: "Check Again",
                    busyTitle: "Checking…",
                    systemImage: "arrow.clockwise",
                    isBusy: isBusy
                ),
                size: CGSize(width: 200, height: 40)
            )
            defer { hosted.close() }
            try await hosted.settle()
            let labels = hosted.labels
            #expect(labels.contains(isBusy ? "Checking…" : "Check Again"), "labels: \(labels)")
            #expect(!labels.contains(isBusy ? "Check Again" : "Checking…"), "labels: \(labels)")
        }
    }
}
