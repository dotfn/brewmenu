import AppKit
import BrewCore
import SwiftUI

/// "Ask AI": opens Claude or ChatGPT with a question about a problem already written in (see
/// `AIAssistant`, `AIPrompt`). For a `brew doctor` finding or a failed command whose fix isn't
/// obvious from Homebrew's own words.
///
/// The question is also put on the clipboard: the links that fill it in aren't all documented,
/// and an empty chat is then one paste away from the same question.
struct AskAIMenu: View {
    /// Built when an assistant is picked, not on every render: it reads the system and home folder.
    let prompt: () -> String

    var body: some View {
        Menu {
            ForEach(AIAssistant.allCases) { assistant in
                Button(L("Ask \(assistant.name)")) { ask(assistant) }
            }
        } label: {
            Label(L("Ask AI"), systemImage: "sparkles")
        }
        .menuStyle(.button)
        .buttonStyle(.roomyBordered)
        .controlSize(.small)
        .fixedSize()
        .help(L("Opens the assistant with the question already written. It's also copied, in case it doesn't show up."))
    }

    private func ask(_ assistant: AIAssistant) {
        let question = prompt()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(question, forType: .string)
        guard let url = assistant.url(asking: question, claudeAppInstalled: Self.claudeAppInstalled) else { return }
        NSWorkspace.shared.open(url)
        AccessibilityNotification.Announcement(L("Opening \(assistant.name). The question is also copied.")).post()
    }

    /// Whether something answers `claude://` links — Claude's desktop app.
    private static var claudeAppInstalled: Bool {
        guard let probe = URL(string: "claude://claude.ai/new") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }
}

extension AIPrompt {
    /// `doctorFinding`, for this Mac.
    static func doctorFinding(_ warning: DoctorWarning) -> String {
        doctorFinding(warning, system: systemDescription(), homeDirectory: NSHomeDirectory())
    }

    /// `failedCommand`, for this Mac.
    static func failedCommand(_ details: String) -> String {
        failedCommand(details, system: systemDescription(), homeDirectory: NSHomeDirectory())
    }
}
