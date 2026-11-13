import Foundation

enum AppTab: String { case control, settings, guests, journal }

/// Debug-only navigation for real simulator screenshots; no credentials or mock data.
enum PreviewRouting {
    static var tab: AppTab {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--preview-tab"), index + 1 < args.count {
            return AppTab(rawValue: args[index + 1]) ?? .control
        }
        #endif
        return .control
    }

    static var keyDetail: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--preview-key-detail")
        #else
        return false
        #endif
    }

    static var addKey: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--preview-add-key")
        #else
        return false
        #endif
    }
}
