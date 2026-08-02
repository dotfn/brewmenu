import AppKit
import SwiftUI

/// Owns the first-run Onboarding window. Extracted verbatim from the old
/// StatusItemController — out of scope for the MenuBarExtra/Dashboard redesign.
@MainActor
final class OnboardingWindowController: NSObject {
    private var onboardingWindow: NSWindow?
    private var onboardingViewModel: OnboardingViewModel?

    func showIfNeeded(_ viewModel: OnboardingViewModel) {
        guard viewModel.needsOnboarding else { return }
        onboardingViewModel = viewModel
        showOnboardingWindow()
    }

    private func showOnboardingWindow() {
        guard let vm = onboardingViewModel else { return }

        // OnboardingView's own onDisappear already handles the X-button dismiss path.
        let view = OnboardingView(viewModel: vm)

        let vc = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: vc)
        window.title = L("Welcome to BrewMenu")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window

        observeOnboardingCompletion(window: window, viewModel: vm)
    }

    private func observeOnboardingCompletion(window: NSWindow, viewModel: OnboardingViewModel) {
        withObservationTracking {
            _ = viewModel.isComplete
        } onChange: { [weak self, weak window] in
            Task { @MainActor in
                window?.close()
                self?.onboardingWindow = nil
                self?.onboardingViewModel = nil
            }
        }
    }
}
