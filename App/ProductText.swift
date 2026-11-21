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
        resolved(key,arguments:arguments,language:language)
    }
    static func date(_ value:Date,dateStyle:Date.FormatStyle.DateStyle = .abbreviated,
                     timeStyle:Date.FormatStyle.TimeStyle = .shortened) -> String {
        value.formatted(Date.FormatStyle(date:dateStyle,time:timeStyle).locale(Locale(identifier:language)))
    }
    private static func resolved(_ key:String,arguments:[CVarArg],language selected:String) -> String {
        let localized = Bundle.main.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let value = localized.localizedString(forKey: key, value: nil, table: "Product")
        return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: selected), arguments: arguments)
    }
    /// Only for text produced by our operation state/error policies. Never use
    /// this for object names, guest names, welcome text or message contents.
    /// Stored status text remains untouched, including comparisons in flight.
    static func systemMessage(_ value:String,language requested:String? = nil) -> String {
        let selected = requested ?? language
        guard selected != "ru",languages.contains(selected) else { return value }
        if let key = systemPhrases[value] { return resolved(key,arguments:[],language:selected) }
        for key in ["ios_system_ble_not_sent_prefix","ios_system_pairing_failed_prefix","ios_system_settings_transfer_failed_prefix"] {
            guard let prefix = russianTable[key],value.hasPrefix(prefix) else { continue }
            let tail = String(value.dropFirst(prefix.count))
            let detail = systemPhrases[tail].map { resolved($0,arguments:[],language:selected) } ?? tail
            return resolved(key,arguments:[],language:selected) + detail
        }
        let key = "ios_system_restored_pending_keys_fmt"
        if let template = russianTable[key] {
            let parts = template.components(separatedBy:"%1$d")
            if parts.count == 2,value.hasPrefix(parts[0]),value.hasSuffix(parts[1]) {
                let digits = value.dropFirst(parts[0].count).dropLast(parts[1].count)
                if !digits.isEmpty,digits.allSatisfy({ $0.isASCII && $0.isNumber }),let count = Int(digits) {
                    return resolved(key,arguments:[count],language:selected)
                }
            }
        }
        return value
    }
    private static let russianTable: [String:String] = {
        guard let folder = Bundle.main.path(forResource:"ru",ofType:"lproj"),
              let bytes = try? Data(contentsOf:URL(fileURLWithPath:folder).appendingPathComponent("Product.strings")),
              let table = try? PropertyListSerialization.propertyList(from:bytes,options:[],format:nil) as? [String:String] else { return [:] }
        return table
    }()
    private static let systemPhrases: [String:String] = {
        var result: [String:String] = [:]
        let borrowed: Set<String> = ["action_request_sent","btn_close","btn_open","guest_call_awaiting",
            "guest_call_busy","guest_call_declined","guest_call_dialing","guest_call_error",
            "press_err_device_offline","press_err_host_offline"]
        // Dedicated outcome translations take precedence over identical short
        // UI labels. Unknown text is returned verbatim.
        for key in russianTable.keys.sorted(by:{ a,b in
            let first = a.hasPrefix("ios_system_"),second = b.hasPrefix("ios_system_")
            return first != second ? first : a < b
        }) {
            guard key.hasPrefix("ios_system_") || borrowed.contains(key),
                  let value = russianTable[key],!value.isEmpty,!value.contains("%"),result[value] == nil else { continue }
            result[value] = key
        }
        return result
    }()
}
