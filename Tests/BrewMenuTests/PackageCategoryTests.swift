import Testing
@testable import BrewMenu

@Suite("PackageCategory")
struct PackageCategoryTests {

    @Test("clasifica herramientas de cloud/infra")
    func classifiesCloudInfrastructure() {
        #expect(PackageCategory.classify(name: "docker", desc: "Pack, ship and run any application as a lightweight container") == .cloudInfrastructure)
        #expect(PackageCategory.classify(name: "terraform", desc: "Tool to build infrastructure as code") == .cloudInfrastructure)
    }

    @Test("clasifica bases de datos como Data")
    func classifiesData() {
        #expect(PackageCategory.classify(name: "postgresql@16", desc: "Object-relational database system") == .data)
        #expect(PackageCategory.classify(name: "redis", desc: "Persistent key-value database") == .data)
    }

    @Test("clasifica runtimes de lenguaje por nombre (con o sin sufijo de versión)")
    func classifiesLanguageRuntime() {
        #expect(PackageCategory.classify(name: "python@3.13", desc: "Interpreted, interactive, object-oriented programming language") == .languageRuntime)
        #expect(PackageCategory.classify(name: "node", desc: "JavaScript runtime environment") == .languageRuntime)
    }

    @Test("NO clasifica como languageRuntime algo solo escrito en ese lenguaje")
    func doesNotMisclassifyToolsWrittenInALanguage() {
        // "warp" menciona "Rust" en la desc pero es una terminal, no un lenguaje/runtime —
        // matchear por nombre en vez de buscar el nombre del lenguaje en cualquier lado
        // evita este falso positivo.
        #expect(PackageCategory.classify(name: "warp", desc: "Rust-based terminal") != .languageRuntime)
    }

    @Test("clasifica git como Developer Tools (revision control)")
    func classifiesGitAsDeveloperTools() {
        #expect(PackageCategory.classify(name: "git", desc: "Distributed revision control system") == .developerTools)
    }

    @Test("clasifica seguridad antes que developer tools")
    func classifiesSecurityOverDeveloperTools() {
        // "openssl" tiene desc genérica que también podría matchear developer tools,
        // pero seguridad tiene prioridad al estar primero en las reglas.
        #expect(PackageCategory.classify(name: "openssl@3", desc: "Cryptography and SSL/TLS Toolkit") == .security)
    }

    @Test("cae en Other cuando no matchea ninguna keyword")
    func fallsBackToOther() {
        #expect(PackageCategory.classify(name: "zzz-mystery-tool", desc: nil) == .other)
    }

    @Test("displayOrder contiene las 12 categorías sin duplicados")
    func displayOrderIsComplete() {
        #expect(Set(PackageCategory.displayOrder) == Set(PackageCategory.allCases))
        #expect(PackageCategory.displayOrder.count == PackageCategory.allCases.count)
    }
}
