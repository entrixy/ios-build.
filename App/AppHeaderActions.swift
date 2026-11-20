import SwiftUI

struct AppLogoMenu: View {
    let help: () -> Void
    var body: some View {
        Menu {
            Menu { AppLanguageChoices() } label: { Label(ProductText.string("ios_language"),systemImage:"globe") }
                .accessibilityIdentifier("header-language")
            Button(action:help) { Label(ProductText.string("tab_help"),systemImage:"questionmark.circle") }
                .accessibilityIdentifier("header-help")
            Link(destination:URL(string:"https://entrixy.com/")!) { Label(ProductText.string("ios_website"),systemImage:"safari") }
                .accessibilityIdentifier("header-website")
        } label: { BrandLogo() }
            .buttonStyle(.plain).foregroundStyle(Brand.ink)
            .accessibilityLabel("Entrixy").accessibilityIdentifier("header-menu")
    }
}

private struct AppLanguageChoices: View {
    @AppStorage("entrixy.language") private var language = ""
    private let choices = [("en","English"),("zh","中文"),("es","Español"),("fr","Français"),("pt","Português"),("ru","Русский"),("de","Deutsch")]
    var body: some View {
        ForEach(choices,id:\.0) { choice in
            Button { language = choice.0 } label: {
                Label { Text(choice.1) } icon: { Image("flag-" + choice.0) }
            }.accessibilityAddTraits(ProductText.language == choice.0 ? .isSelected : [])
        }
    }
}

/// MainActivity topBar: help first, then the original language flag/menu.
struct AppHeaderActions: View {
    @AppStorage("entrixy.language") private var language = ""
    var showHelp = true
    var body: some View {
        HStack(spacing:0) {
            if showHelp { NavigationLink { HelpScreen() } label: {
                Image(systemName:"questionmark.circle").font(.system(size:19)).frame(width:44,height:44)
            }.accessibilityLabel(ProductText.string("tab_help")).accessibilityIdentifier("header-help") }
            Menu {
                AppLanguageChoices()
            } label: {
                Image("flag-" + ProductText.language).resizable().interpolation(.high).frame(width:17,height:11).frame(width:44,height:44).contentShape(Rectangle())
            }.accessibilityLabel(ProductText.string("ios_language")).accessibilityIdentifier("header-language")
        }.buttonStyle(.plain).foregroundStyle(Brand.ink)
    }
}

struct HelpScreen: View {
    @AppStorage("entrixy.developerMode") private var developerMode = false
    @State private var developerTaps = 0
    @State private var developerFeedback: String?
    private let sections = [("help_section_actions","help_c_control"),("help_section_objects","help_c_objects"),("help_section_auto","ios_help_auto"),("help_section_guests","help_c_guests"),("help_section_security","help_c_security"),("help_section_permissions","ios_help_permissions")]
    private var guide: URL {
        let language = ProductText.language
        return URL(string:"https://entrixy.com" + (language == "en" ? "" : "/" + language) + "/guide/")!
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                Text(ProductText.string("help_title")).font(.title2.weight(.semibold))
                Text(ProductText.string("help_subtitle_short")).font(.footnote).foregroundStyle(Brand.secondaryInk).padding(.bottom,4)
                ForEach(sections,id:\.0) { section in
                    VStack(alignment:.leading,spacing:10) {
                        Text(ProductText.string(section.0)).font(.headline)
                        Text(ProductText.string(section.1)).font(.body).lineSpacing(3)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(16).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
                }
                Link(destination:guide) { Label(ProductText.string("help_full_guide"),systemImage:"arrow.up.right.square").frame(maxWidth:.infinity,minHeight:48) }.buttonStyle(PrimaryActionStyle())
                if let developerFeedback { Text(developerFeedback).font(.footnote).foregroundStyle(Brand.secondaryInk) }
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")).font(.footnote).foregroundStyle(Brand.secondaryInk).frame(maxWidth:.infinity,alignment:.trailing).padding(.top,12)
                    .contentShape(Rectangle()).accessibilityIdentifier("help-version").onTapGesture {
                        guard !developerMode else { return }; developerTaps += 1
                        if developerTaps >= 7 { developerMode = true; developerFeedback = ProductText.string("dev_mode_on") }
                        else if developerTaps >= 4 { developerFeedback = ProductText.string("dev_mode_left_fmt",7-developerTaps) }
                    }
            }.padding(DesignMetrics.pageInset)
        }.background(Color(uiColor:.systemGroupedBackground)).navigationTitle(ProductText.string("tab_help")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) { ToolbarItem(placement:.navigationBarTrailing) { AppHeaderActions(showHelp:false) }.sharedBackgroundVisibility(.hidden) }
                else { ToolbarItem(placement:.navigationBarTrailing) { AppHeaderActions(showHelp:false) } }
            }
    }
}
