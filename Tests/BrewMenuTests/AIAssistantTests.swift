import BrewCore
@testable import BrewMenu
import Foundation
import Testing

@Suite("Preguntar a la IA — enlace y pregunta")
struct AIAssistantTests {
    @Test("la pregunta va entera en el enlace: nada se lee como sintaxis de URL")
    func promptIsFullyEncoded() throws {
        let prompt = "a & b + c = d?\n#ñ"

        let url = try #require(AIAssistant.chatGPT.url(asking: prompt, claudeAppInstalled: false))

        #expect(url.absoluteString == "https://chatgpt.com/?q=a%20%26%20b%20%2B%20c%20%3D%20d%3F%0A%23%C3%B1")
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        #expect(decoded == prompt)
    }

    @Test("Claude: la app de escritorio cuando está, la web si no")
    func claudeLinkFollowsTheApp() throws {
        let app = try #require(AIAssistant.claude.url(asking: "hi", claudeAppInstalled: true))
        let web = try #require(AIAssistant.claude.url(asking: "hi", claudeAppInstalled: false))

        #expect(app.absoluteString == "claude://claude.ai/new?q=hi")
        #expect(web.absoluteString == "https://claude.ai/new?q=hi")
    }

    @Test("la pregunta cita el aviso, dice qué sistema es y no lleva la carpeta del usuario")
    func doctorPromptQuotesTheFinding() {
        let warning = DoctorWarning(severity: .warning, message: "Warning: Unbrewed files in /Users/someone/Foo.")
        let system = "macOS 26.1, Apple silicon"

        let prompt = AIPrompt.doctorFinding(warning, system: system, homeDirectory: "/Users/someone")

        #expect(prompt.contains("macOS 26.1, Apple silicon"))
        #expect(prompt.contains("Warning: Unbrewed files in ~/Foo."))
        #expect(!prompt.contains("/Users/someone"))
    }

    @Test("un registro largo se corta por el medio: quedan el comando y el final con el error")
    func longOutputKeepsItsEnds() {
        let details = "brew install foo\n" + String(repeating: "noise\n", count: 2000) + "Error: the real reason"

        let prompt = AIPrompt.failedCommand(details, system: "macOS 26.1, Apple silicon", homeDirectory: "/Users/x")

        #expect(prompt.contains("brew install foo"))
        #expect(prompt.contains("Error: the real reason"))
        #expect(prompt.count < AIPrompt.maxQuotedLength + 400)
    }
}

@Suite("Preguntar a la IA — instalación fallida")
@MainActor
struct InstallFailureReportTests {
    @Test("el informe de una instalación fallida lleva el comando y el motivo")
    func reportCarriesCommandAndReason() async throws {
        let service = MockBrewServiceForDashboard()
        await service.setInstallError(BrewError.commandFailed(exitCode: 1, stderr: "Error: nope"))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService())

        vm.installSingle(name: "wget", isCask: false)
        try await waitUntil { !vm.isInstallRunning }

        let report = vm.installFailureReport(name: "wget")
        #expect(report.hasPrefix("brew install wget"))
        #expect(report.contains("Error: nope"))
    }
}
