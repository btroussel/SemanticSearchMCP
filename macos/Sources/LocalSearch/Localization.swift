import Foundation
import Combine

/// Language choices are discovered from standard .lproj resources, including future translations.
final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    static let preferenceKey = "appLanguage"
    private let defaults: UserDefaults
    let resources: Bundle
    @Published var language: String {
        didSet { defaults.set(language, forKey: Self.preferenceKey) }
    }

    init(defaults: UserDefaults = .standard, resources: Bundle = .module) {
        self.defaults = defaults
        self.resources = resources
        let saved = defaults.string(forKey: Self.preferenceKey) ?? ""
        language = resources.localizations.contains(saved) ? saved : ""
    }

    var supportedLanguages: [String] { resources.localizations.filter { $0 != "Base" }.sorted() }
    var resolvedLanguage: String {
        Self.resolve(language: language, supported: supportedLanguages, preferred: Locale.preferredLanguages)
    }
    static func resolve(language: String, supported: [String], preferred: [String]) -> String {
        if supported.contains(language) { return language }
        return Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first ?? "en"
    }
    var locale: Locale { Locale(identifier: resolvedLanguage) }
    func name(for language: String) -> String {
        Locale(identifier: language).localizedString(forIdentifier: language) ?? language
    }
    private func bundle(for language: String) -> Bundle? {
        guard let path = resources.path(forResource: language, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
    func string(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments)
    }
    func format(_ key: String, arguments: [CVarArg]) -> String {
        // A partial new translation falls back to English per key, never to an internal identifier.
        let fallback = bundle(for: "en")?.localizedString(forKey: key, value: nil, table: nil) ?? key
        let format = bundle(for: resolvedLanguage)?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }
}

enum L10n {
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        AppLocalization.shared.format(key, arguments: arguments)
    }
    /// "Indexed 5 min ago", in the interface language.
    static func indexed(_ date: Date) -> String {
        guard Date().timeIntervalSince(date) >= 60 else { return string("source.indexedNow") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocalization.shared.locale
        formatter.unitsStyle = .short
        return string("source.indexedAgo", formatter.localizedString(for: date, relativeTo: Date()))
    }
    static func assetKind(_ kind: String) -> String {
        switch kind {
        case "code", "documents", "images": return string("type." + kind)
        default: return kind
        }
    }
}
