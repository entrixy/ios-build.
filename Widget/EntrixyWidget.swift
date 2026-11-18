import WidgetKit
import SwiftUI
import AppIntents

private struct ObjectWidgetEntry: TimelineEntry {
    let date: Date
    let object: WidgetObject?
}

private struct ObjectWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = ObjectWidgetConfiguration
    func placeholder(in context: Context) -> ObjectWidgetEntry { ObjectWidgetEntry(date:Date(),object:nil) }
    func snapshot(for configuration: Intent, in context: Context) async -> ObjectWidgetEntry { entry(configuration,at:Date()) }
    func timeline(for configuration: Intent, in context: Context) async -> Timeline<ObjectWidgetEntry> {
        let now = Date()
        // A foreground observation expires in the widget too. An archived
        // snapshot is not evidence of a live BLE or server connection.
        return Timeline(entries:[entry(configuration,at:now),entry(configuration,at:now.addingTimeInterval(15))],policy:.after(now.addingTimeInterval(300)))
    }
    private func entry(_ configuration: Intent, at date: Date) -> ObjectWidgetEntry {
        ObjectWidgetEntry(date:date,object:WidgetCatalog.load().objects.first { $0.id == configuration.object?.id })
    }
}

private struct ObjectWidgetView: View {
    let entry: ObjectWidgetEntry
    private var statusColor: Color {
        switch entry.object?.currentStatus(at:entry.date) {
        case .ready: return Color(red:149/255,green:193/255,blue:31/255)
        case .connecting: return .orange
        case .neutral: return Color(red:26/255,green:86/255,blue:168/255)
        default: return Color(red:226/255,green:116/255,blue:116/255)
        }
    }
    var body: some View {
        Button(intent:WidgetObjectTapIntent(objectID:entry.object?.id ?? "")) {
            VStack(spacing:10) {
                Group {
                    if let item = entry.object {
                        Group {
                            if let name = item.image, let url = WidgetCatalog.imageURL(name),
                               let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= 32768,
                               let image = UIImage(contentsOfFile:url.path) {
                                Image(uiImage:image).resizable().scaledToFill()
                            } else { Image("object-\(item.preset+1)").resizable().scaledToFill() }
                        }
                        .frame(width:56,height:56).clipShape(RoundedRectangle(cornerRadius:14))
                        .overlay(alignment:.bottomTrailing) { Circle().fill(statusColor).frame(width:10,height:10).offset(x:-8,y:-8) }
                    } else { Image("icon-key").resizable().scaledToFit().frame(width:56,height:56) }
                }.accessibilityHidden(true)
                Text(entry.object?.label ?? "Entrixy").font(.headline).multilineTextAlignment(.center).lineLimit(3)
                    .foregroundStyle(.primary)
            }.frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .containerBackground(.background,for:.widget)
            .privacySensitive()
    }
}

@main
struct EntrixyObjectWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind:WidgetCatalog.kind,intent:ObjectWidgetConfiguration.self,provider:ObjectWidgetProvider()) { entry in
            ObjectWidgetView(entry:entry)
        }
        .configurationDisplayName("Entrixy")
        .description("Control an object from your Home Screen.")
        .supportedFamilies([.systemSmall])
    }
}
