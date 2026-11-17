import Foundation

enum ProductText {
    static let languages = ["en", "ru", "de", "es", "fr", "pt", "zh"]
    static var language: String {
        let saved = UserDefaults.standard.string(forKey:"entrixy.language")
        let requested = saved?.isEmpty == false ? saved! : Locale.preferredLanguages.first ?? "en"
        let language = requested.split(separator: "-").first.map(String.init) ?? "en"
        return languages.contains(language) ? language : "en"
    }
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        let selected = language
        let localized = Bundle.main.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let value = localized.localizedString(forKey: key, value: nil, table: "Product")
        return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: selected), arguments: arguments)
    }
}
