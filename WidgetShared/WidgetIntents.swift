import AppIntents
import Foundation

@available(iOS 17.0, *)
struct WidgetObjectEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Object"
    static var defaultQuery = WidgetObjectQuery()
    let id: String
    let label: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title:"\(label)") }
    init(_ item: WidgetObject) { id = item.id; label = item.label }
}

@available(iOS 17.0, *)
struct WidgetObjectQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetObjectEntity] {
        let catalog = WidgetCatalog.load().objects
        return identifiers.compactMap { id in catalog.first { $0.id == id }.map(WidgetObjectEntity.init) }
    }
    func suggestedEntities() async throws -> [WidgetObjectEntity] { WidgetCatalog.load().objects.map(WidgetObjectEntity.init) }
    func entities(matching string: String) async throws -> [WidgetObjectEntity] {
        WidgetCatalog.load().objects.filter { $0.label.localizedCaseInsensitiveContains(string) }.map(WidgetObjectEntity.init)
    }
}

@available(iOS 17.0, *)
struct ObjectWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Pick an object"
    static var description = IntentDescription("Choose an object from Entrixy.")
    @Parameter(title:"Object") var object: WidgetObjectEntity?
}

@available(iOS 17.0, *)
struct WidgetObjectTapIntent: AppIntent {
    static var title: LocalizedStringResource = "Use object"
    // The protected action engine belongs to the app, including entry unlock,
    // fresh connection, PIN/biometrics and confirmation. Never call a transport
    // from the extension or expose a fire action through a custom URL scheme.
    static var openAppWhenRun = true
    static var isDiscoverable = false
    @Parameter(title:"Object") var objectID: String
    init() { objectID = "" }
    init(objectID: String) { self.objectID = objectID }
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await WidgetActionInbox.shared.enqueue(objectID)
        #endif
        return .result()
    }
}
