import Foundation

/// Android JournalEntry: the initiator, target and actual action result.
/// Legacy connection diagnostics decode without who/what and are discarded on load.
struct JournalEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let who: String
    let what: String
    let actionKey: String
    var result: String
    var level: String

    init(who: String, what: String, actionKey: String = "", date: Date = Date(), result: String = "", level: String = "") {
        id = UUID()
        self.date = date
        self.who = who
        self.what = what
        self.actionKey = actionKey
        self.result = result
        self.level = level
    }

    var isAction: Bool { !who.isEmpty && !what.isEmpty }
    private enum CodingKeys: String, CodingKey { case id, date, who, what, actionKey, result, level }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try values.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
        who = try values.decodeIfPresent(String.self, forKey: .who) ?? ""
        what = try values.decodeIfPresent(String.self, forKey: .what) ?? ""
        actionKey = try values.decodeIfPresent(String.self, forKey: .actionKey) ?? ""
        result = try values.decodeIfPresent(String.self, forKey: .result) ?? ""
        level = try values.decodeIfPresent(String.self, forKey: .level) ?? ""
    }
}

enum GuestConnection: Equatable {
    case connecting, connected, offline, unavailable
    var title: String {
        switch self {
        case .connecting: return "Подключение…"
        case .connected: return "Сервер на связи"
        case .offline: return "Нет соединения"
        case .unavailable: return "Ключ недоступен"
        }
    }
}
