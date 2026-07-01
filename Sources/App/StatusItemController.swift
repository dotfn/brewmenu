import AppKit
import SwiftUI

/// Owns the NSStatusItem and NSPopover that make up the menu bar presence.
/// Left-click toggles the popover; right-click shows a context menu.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel: MenuBarViewModel
    private let settingsViewModel: SettingsViewModel
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingViewModel: OnboardingViewModel?

    init(
        viewModel: MenuBarViewModel,
        settingsViewModel: SettingsViewModel,
        onboardingViewModel: OnboardingViewModel
    ) {
        self.viewModel = viewModel
        self.settingsViewModel = settingsViewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        super.init()

        // The openSettings closure is captured after super.init() so `self` is available.
        let hostingController = NSHostingController(
            rootView: MenuBarView(viewModel: viewModel, openSettings: { [weak self] in
                self?.showSettingsWindow()
            })
        )
        popover.contentViewController = hostingController
        popover.behavior = .transient

        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.target = self

        observeStatus()

        if onboardingViewModel.needsOnboarding {
            self.onboardingViewModel = onboardingViewModel
            showOnboardingWindow()
        }
    }

    // MARK: - Click handling

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Configuración…",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Salir de BrewMenu",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        ))

        // Assigning `menu` and calling performClick shows the menu in a modal loop;
        // performClick returns only after the menu is dismissed, so resetting is safe here.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func handleOpenSettings() {
        showSettingsWindow()
    }

    // MARK: - Settings window

    private func showSettingsWindow() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vc = NSHostingController(rootView: SettingsView(viewModel: settingsViewModel))
        let window = NSWindow(contentViewController: vc)
        window.title = "BrewMenu"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    // MARK: - Icon

    private func observeStatus() {
        withObservationTracking {
            updateIcon(status: viewModel.status)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeStatus() }
        }
    }

    private func updateIcon(status: MenuBarStatus) {
        let cfg = NSImage.SymbolConfiguration(paletteColors: [NSColor(status.menuBarColor)])
        guard let img = NSImage(systemSymbolName: status.menuBarSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return }
        img.isTemplate = false
        img.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = img
    }

    // MARK: - Onboarding

    private func showOnboardingWindow() {
        guard let vm = onboardingViewModel else { return }

        // onDisappear handles the X-button dismiss path (no "Comenzar" tap).
        let view = OnboardingView(viewModel: vm)
            .onDisappear { [weak vm] in Task { await vm?.completeSkipped() } }

        let vc = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: vc)
        window.title = "Bienvenido a BrewMenu"
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

// MARK: - MenuBarStatus → icon

private extension MenuBarStatus {
    var menuBarSymbol: String {
        switch self {
        case .initializing: "hourglass"
        case .ok: "mug.fill"
        case .updates: "mug.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var menuBarColor: Color {
        switch self {
        case .initializing: .secondary
        case .ok: .green
        case .updates: .yellow
        case .warning: .orange
        case .error: .red
        }
    }
}
