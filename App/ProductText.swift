import Foundation

enum ProductText {
    static let languages = ["en", "ru", "de", "es", "fr", "pt", "zh"]
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        let requested = UserDefaults.standard.string(forKey: "entrixy.language")
            ?? Locale.preferredLanguages.first ?? "en"
        let language = requested.split(separator: "-").first.map(String.init) ?? "en"
        let selected = languages.contains(language) ? language : "en"
        let localized = Bundle.main.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let value = localized.localizedString(forKey: key, value: nil, table: "Product")
        return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: selected), arguments: arguments)
    }
}
