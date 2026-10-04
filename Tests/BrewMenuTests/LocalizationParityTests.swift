import BrewCore
import Foundation
import Testing

/// Guards the .strings catalogues against drift: a key added in English without its Spanish
/// counterpart shows up in Spanish as raw English, and a literal `L("…")` with no key fails silently.
@Suite("Localization parity")
struct LocalizationParityTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func keys(in path: String) throws -> Set<String> {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        var keys: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let match = line.firstMatch(of: /^"((?:[^"\\]|\\.)*)"\s*=/) else { continue }
            keys.insert(String(match.1).replacingOccurrences(of: "\\\"", with: "\""))
        }
        return keys
    }

    @Test("en y es tienen exactamente las mismas claves")
    func englishAndSpanishHaveSameKeys() throws {
        let en = try Self.keys(in: "Sources/Resources/en.lproj/Localizable.strings")
        let es = try Self.keys(in: "Sources/Resources/es.lproj/Localizable.strings")
        #expect(en.subtracting(es).isEmpty, "solo en inglés: \(en.subtracting(es).sorted())")
        #expect(es.subtracting(en).isEmpty, "solo en español: \(es.subtracting(en).sorted())")
    }

    @Test("cada L(\"…\") literal del código tiene su clave en inglés")
    func everyLiteralKeyExists() throws {
        let en = try Self.keys(in: "Sources/Resources/en.lproj/Localizable.strings")
        let sources = FileManager.default.enumerator(
            at: Self.root.appendingPathComponent("Sources"),
            includingPropertiesForKeys: nil
        )
        var missing: Set<String> = []
        while let url = sources?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in text.matches(of: /\bL\("((?:[^"\\]|\\.)*)"\)/) {
                let key = String(match.1).replacingOccurrences(of: "\\\"", with: "\"")
                // Interpolated keys are looked up with format specifiers; only literals are checked here.
                guard !key.contains("\\(") else { continue }
                if !en.contains(key) { missing.insert(key) }
            }
        }
        #expect(missing.isEmpty, "sin clave en en.strings: \(missing.sorted())")
    }
}
