import XCTest
@testable import LocalSearch

final class LocalizationTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var localization: AppLocalization!

    override func setUp() {
        suite = "LocalSearchTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        localization = AppLocalization(defaults: defaults)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testSystemLanguageMatchingAndEnglishFallback() {
        XCTAssertEqual(localization.language, "")
        XCTAssertTrue(Set(["en", "fr"]).isSubset(of: Set(localization.supportedLanguages)))
        XCTAssertEqual(AppLocalization.resolve(language: "", supported: ["en", "fr"], preferred: ["fr-CA", "en-US"]), "fr")
        XCTAssertEqual(AppLocalization.resolve(language: "", supported: ["en", "fr"], preferred: ["ja-JP"]), "en")
        XCTAssertEqual(AppLocalization.resolve(language: "en", supported: ["en", "fr"], preferred: ["fr-FR"]), "en")
        XCTAssertEqual(AppLocalization.resolve(language: "removed", supported: ["en", "fr"], preferred: ["fr-FR"]), "fr")
        XCTAssertEqual(AppLocalization.resolve(language: "", supported: ["en", "es", "fr"], preferred: ["es-MX"]), "es")
    }

    func testLanguageChangesImmediatelyAndPersists() {
        localization.language = "fr"
        XCTAssertEqual(localization.string("action.search"), "Rechercher")
        XCTAssertEqual(AppLocalization(defaults: defaults).language, "fr")
        localization.language = "en"
        XCTAssertEqual(localization.string("action.search"), "Search")
        XCTAssertEqual(localization.string("preview.lines", 10, 24), "Lines 10–24")
        XCTAssertEqual(localization.string("source.types", "Code, Images"), "Allowed types: Code, Images")
        defaults.set("removed-language", forKey: AppLocalization.preferenceKey)
        XCTAssertEqual(AppLocalization(defaults: defaults).language, "")
    }

    func testPluralCountsInBothLanguages() {
        localization.language = "en"
        XCTAssertEqual(localization.string("count.files", 0), "0 files")
        XCTAssertEqual(localization.string("count.files", 1), "1 file")
        XCTAssertEqual(localization.string("count.files", 2), "2 files")
        XCTAssertEqual(localization.string("count.items", 1), "1 item")
        XCTAssertEqual(localization.string("count.results", 2), "2 results")
        XCTAssertEqual(localization.string("count.unreadableFiles", 1), "1 file could not be read")
        XCTAssertEqual(localization.string("count.copies", 1), "Identical copy in 1 other location")
        localization.language = "fr"
        XCTAssertEqual(localization.string("count.files", 0), "0 fichier")
        XCTAssertEqual(localization.string("count.files", 1), "1 fichier")
        XCTAssertEqual(localization.string("count.files", 2), "2 fichiers")
        XCTAssertEqual(localization.string("count.items", 2), "2 éléments")
        XCTAssertEqual(localization.string("count.results", 1), "1 résultat")
        XCTAssertEqual(localization.string("count.unreadableFiles", 2), "2 fichiers n’ont pas pu être lus")
        XCTAssertEqual(localization.string("count.copies", 2), "Copies identiques dans 2 autres emplacements")
    }

    func testIncompleteTranslationFallsBackToEnglish() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: url) }
        for language in ["en", "fr"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(language + ".lproj"), withIntermediateDirectories: true)
        }
        try "\"test.label\" = \"English fallback\";".write(to: url.appendingPathComponent("en.lproj/Localizable.strings"), atomically: true, encoding: .utf8)
        try "\"other.label\" = \"Autre\";".write(to: url.appendingPathComponent("fr.lproj/Localizable.strings"), atomically: true, encoding: .utf8)
        let testLocalization = AppLocalization(defaults: defaults, resources: try XCTUnwrap(Bundle(url: url)))
        testLocalization.language = "fr"
        XCTAssertEqual(testLocalization.string("test.label"), "English fallback")
        XCTAssertEqual(testLocalization.string("other.label"), "Autre")
    }

    func testCatalogKeysAndFormatPlaceholdersMatch() throws {
        func catalog(_ language: String, _ ext: String) throws -> [String: Any] {
            let path = try XCTUnwrap(localization.resources.path(forResource: "Localizable", ofType: ext, inDirectory: language + ".lproj"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: Any])
        }
        let english = try catalog("en", "strings")
        let placeholders = try NSRegularExpression(pattern: "%([0-9]+\\$)?(?:@|lld)")
        func formats(_ value: String) -> [String] {
            placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range, in: value)!])
            }.sorted()
        }
        for language in localization.supportedLanguages {
            let translated = try catalog(language, "strings")
            XCTAssertEqual(Set(translated.keys), Set(english.keys), language)
            for (key, value) in english {
                let translation = try XCTUnwrap(translated[key] as? String, key)
                XCTAssertFalse(translation.isEmpty, key)
                XCTAssertEqual(formats(translation), formats(value as! String), key)
            }
            XCTAssertEqual(Set(try catalog(language, "stringsdict").keys), Set(try catalog("en", "stringsdict").keys))
        }
    }
}
