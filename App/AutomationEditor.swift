import SwiftUI
import UIKit
import EntrixyCore

struct AutomationEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let destination: AutomationDestination
    var contextOverride: AutomationSettingsContext? = nil
    var saveOverride: ((AutomationTemplate) -> Bool)? = nil
    @State private var codeSetup = false
    @State private var message: String?
    private var context: AutomationSettingsContext? { contextOverride ?? (try? model.automationContext(destination)) }
    private func text(_ key: String) -> String { ProductText.string(key) }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let c = context {
                    VStack(alignment: .leading, spacing: 14) {
                        if !(c.incoming && c.template.combineLevel == .force) { activation(c) }
                        Text(text("automation_rules_header")).font(.headline)
                        if c.isBLE {
                            rule(c, title: "BLE", symbol: "wave.3.right", enabled: \.bleEnabled, level: \.bleLevel) {
                                Text(ProductText.string("guest_auto_radius_fmt", max(1,c.template.bleRadiusM)))
                                let maximum = max(1, c.template.ownerBleRadiusMaxM ?? 30)
                                Slider(value: number(c, \.bleRadiusM, minimum: 1, maximum: maximum), in: 1...Double(max(2,maximum)), step: 1)
                                    .disabled(maximum == 1)
                            }
                        }
                        rule(c, title: text("automation_rule_geo"), symbol: "location", enabled: \.geoEnabled, level: \.geoLevel) {
                            AutomationGeoFields(context: c, sensors: model.automationSensors, change: change)
                        }
                        rule(c, title: text("automation_rule_wifi"), symbol: "wifi", enabled: \.wifiEnabled, level: \.wifiLevel) {
                            AutomationWiFiFields(context: c, sensors: model.automationSensors, change: change)
                        }
                        rule(c, title: text("automation_rule_time"), symbol: "clock", enabled: \.timeEnabled, level: \.timeLevel) {
                            AutomationTimeFields(template: c.template, readOnly: c.incoming && c.template.timeLevel == .force) { rows in
                                change { $0.timeEntries = rows }
                            }
                        }
                        Text(text("automation_section_before")).font(.headline).padding(.top, 8)
                        rule(c, title: text("automation_rule_auth"), symbol: "person.badge.key", enabled: \.authEnabled, level: \.authLevel) {
                            Text(text("automation_auth_code"))
                        }
                        rule(c, title: text("automation_rule_confirm"), symbol: "hand.tap", enabled: \.confirmEnabled, level: \.confirmLevel) {
                            Text(text(c.incoming ? "automation_confirm_hint_guest" : "automation_confirm_hint")).foregroundStyle(Brand.secondaryInk)
                        }
                        if let message { Text(message).foregroundStyle(.red) }
                    }.padding(DesignMetrics.pageInset).disabled(!c.canEdit)
                } else { Text(text("object_unavailable")).padding(DesignMetrics.pageInset) }
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .sheetDismissFooter(text("btn_close")) { dismiss() }
                .task {
                    if let c = context, c.template.authEnabled, (!c.issued || c.isBLE), !model.hasActionCode { codeSetup = true }
                    model.automationSensors.refreshNetwork()
                }
        }
        .accessibilityHidden(codeSetup)
        .overlay {
            if codeSetup { AutomationCodeSetup { codeSetup = false } }
        }
        .onChange(of:codeSetup) { if !$0 { finishCodeSetup() } }
        .onAppear { model.automation.beginEditing() }
        .onDisappear { model.automation.endEditing() }
    }
    private var title: String {
        guard let c = context else { return text("automation_icon_desc") }
        return ProductText.string(c.issued && !c.isBLE ? "guest_tpl_title" : "owner_tpl_title", c.label)
    }
    private func activation(_ c: AutomationSettingsContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("automation_combine_header")).font(.headline)
                Spacer()
                if c.issued { levelMenu(c.template.combineLevel) { level in change { $0.combineLevel = level } } }
            }
            ForEach(["any", "all"], id: \.self) { value in
                Button { change { $0.combineMode = value } } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: c.template.combineMode == value ? "largecircle.fill.circle" : "circle").padding(.top, 2)
                        Text(text(value == "any" ? "automation_combine_any" : "automation_combine_all"))
                            .foregroundStyle(Brand.ink).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain)
            }
        }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
    @ViewBuilder private func rule<Content: View>(_ c: AutomationSettingsContext, title: String, symbol: String,
        enabled: WritableKeyPath<AutomationTemplate, Bool>, level: WritableKeyPath<AutomationTemplate, AutomationRuleLevel>,
        @ViewBuilder content: () -> Content) -> some View {
        let value = c.template[keyPath: enabled], decision = c.template[keyPath: level]
        let isBefore = enabled == \.authEnabled || enabled == \.confirmEnabled
        let locked = c.incoming && (decision == .force || (!isBefore && c.template.combineLevel == .force && c.template.combineMode == "all"))
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: symbol).frame(width: 38, height: 38)
                    .background((c.issued ? color(decision) : Brand.primary).opacity(value ? 0.16 : 0.07), in: Circle())
                    .foregroundStyle(value ? (c.issued ? color(decision) : Brand.ink) : Brand.secondaryInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if c.issued { levelMenu(decision) { selected in change { $0[keyPath: level] = selected } } }
                }
                Spacer(minLength: 0)
                Toggle(title, isOn: Binding(get: { value }, set: { on in
                    change {
                        $0[keyPath: enabled] = on
                        if enabled == \.authEnabled { $0.authMode = on ? ($0.authMode ?? "pin") : nil }
                        if enabled == \.confirmEnabled { $0.requireConfirmation = on }
                    }
                    if enabled == \.authEnabled, on, (!c.issued || c.isBLE), !model.hasActionCode { codeSetup = true }
                })).labelsHidden().disabled(locked)
            }
            if value && (!c.issued || decision != .own) { content() }
        }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
    private func levelMenu(_ value: AutomationRuleLevel, select: @escaping (AutomationRuleLevel) -> Void) -> some View {
        Menu {
            ForEach(AutomationRuleLevel.allCases, id: \.self) { level in
                Button(text("guest_tpl_lvl_" + level.rawValue)) { select(level) }
            }
        } label: { Label(text("guest_tpl_lvl_" + value.rawValue), systemImage: "chevron.down").font(.subheadline) }
    }
    private func color(_ level: AutomationRuleLevel) -> Color { switch level { case .own: return .green; case .suggest: return .orange; case .force: return .red } }
    private func number(_ c: AutomationSettingsContext, _ key: WritableKeyPath<AutomationTemplate, Int>, minimum: Int, maximum: Int) -> Binding<Double> {
        Binding(get: { Double(min(maximum,max(minimum,c.template[keyPath: key]))) }, set: { value in change { $0[keyPath: key] = Int(value) } })
    }
    private func change(_ update: (inout AutomationTemplate) -> Void) {
        guard let current = context else { return }
        var copy = current.template; update(&copy)
        message = (saveOverride?(copy) ?? model.saveAutomation(current, template: copy)) ? nil : "Не удалось сохранить изменение. Прежние настройки сохранены."
    }
    private func finishCodeSetup() {
        guard !model.hasActionCode, let c = context, !(c.incoming && c.template.authLevel == .force) else { return }
        change { $0.authEnabled = false; $0.authMode = nil }
    }
}

private struct AutomationGeoFields: View {
    let context: AutomationSettingsContext
    @ObservedObject var sensors: AutomationSensors
    let change: ((inout AutomationTemplate) -> Void) -> Void
    @State private var showingMap = false
    private var t: AutomationTemplate { context.template }
    private var fromObject: Bool { context.issued && t.geoFromOwner }
    private var geometry: AutomationTemplate { fromObject ? t.resolvingGeo(from: context.objectTemplate ?? AutomationTemplate()) : t }
    private var readOnly: Bool { fromObject || (context.incoming && t.geoLevel == .force) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if context.issued && !context.isBLE, let own = context.objectTemplate,
               (own.geoLat != nil && own.geoLon != nil) || !own.corridors.isEmpty || t.geoFromOwner {
                Toggle(ProductText.string("automation_geo_as_object"), isOn: Binding(get: { t.geoFromOwner }, set: { on in
                    change { value in if !on { value = value.resolvingGeo(from: own) }; value.geoFromOwner = on }
                }))
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ProductText.string("guest_tpl_point")).font(.headline)
                    if let lat = geometry.geoLat, let lon = geometry.geoLon {
                        Text(String(format: "%.6f, %.6f", lat, lon)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    } else { Text(ProductText.string("guest_tpl_point_unset")).foregroundStyle(Brand.secondaryInk) }
                }
                Spacer()
                if let lat = geometry.geoLat, let lon = geometry.geoLon {
                    Button { UIPasteboard.general.string = String(format: "%.6f, %.6f", lat, lon) } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel(ProductText.string("btn_copy"))
                    if !readOnly {
                        Button(role: .destructive) { change { $0.geoLat = nil; $0.geoLon = nil } } label: { Image(systemName: "trash") }
                            .accessibilityLabel(ProductText.string("btn_delete"))
                    }
                }
            }
            if !readOnly {
                Button {
                    Task { if let point = try? await sensors.currentLocation() { change { $0.geoLat = point.coordinate.latitude; $0.geoLon = point.coordinate.longitude } } }
                } label: { Label(ProductText.string(sensors.locating ? "action_gps_fetching" : "automation_geo_use_current"), systemImage: "location") }
                    .buttonStyle(SecondaryActionStyle()).disabled(sensors.locating)
            }
            if !readOnly || !geometry.corridors.isEmpty {
                Button {
                    showingMap = true
                } label: {
                    Label(geometry.corridors.isEmpty ? ProductText.string("automation_geo_draw_route") : ProductText.string("automation_geo_route_count",geometry.corridors.count), systemImage: "pencil.tip")
                }.buttonStyle(SecondaryActionStyle())
            }
            if geometry.corridors.isEmpty {
                let maximum = context.incoming && t.geoLevel == .force ? min(200,max(10,t.ownerRadiusMaxM ?? t.radiusM ?? 200)) : 200
                Text(ProductText.string("owner_radius_status", geometry.radiusM ?? 30))
                if !fromObject {
                    Slider(value: Binding(get: { Double(min(maximum,max(10,t.radiusM ?? 30))) }, set: { v in change { $0.radiusM = Int(v) } }), in: 10...Double(max(11,maximum)), step: 5)
                        .disabled(maximum == 10)
                }
            }
            if let message = sensors.message { Text(message).font(.footnote).foregroundStyle(Brand.secondaryInk) }
        }.fullScreenCover(isPresented: $showingMap) {
            AutomationRouteMap(sensors: sensors,
                gate: geometry.geoLat.flatMap { lat in geometry.geoLon.map { AutomationGeoPoint(lat: lat,lon: $0) } },
                routes: geometry.corridors, readOnly: readOnly) { gate, routes in
                    change { $0.geoLat = gate?.lat; $0.geoLon = gate?.lon; $0.corridors = routes; $0.geoMode = routes.isEmpty ? "zone" : "route" }
                }
        }
    }
}

private struct AutomationWiFiFields: View {
    let context: AutomationSettingsContext
    @ObservedObject var sensors: AutomationSensors
    let change: ((inout AutomationTemplate) -> Void) -> Void
    private var t: AutomationTemplate { context.template }
    private var readOnly: Bool { context.incoming && t.wifiLevel == .force }
    private var networkGroups: [String: [Int]] {
        Dictionary(grouping: t.wifiBssids.indices) { index in
            index < t.wifiSsids.count && !t.wifiSsids[index].isEmpty ? t.wifiSsids[index] : "—"
        }
    }
    private var networkNames: [String] { networkGroups.keys.sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(ProductText.string("guest_tpl_wifi_mode"), selection: Binding(get: { t.wifiMode }, set: { value in change { $0.wifiMode = value } })) {
                Text(ProductText.string("automation_wifi_mode_connect")).tag("connect")
                Text(ProductText.string("automation_wifi_mode_fp")).tag("fingerprint")
            }.pickerStyle(.segmented).disabled(readOnly)
            if t.wifiMode == "connect" {
                if !t.wifiConnectSsid.isEmpty {
                    HStack {
                        Text(t.wifiConnectSsid); Spacer()
                        if !readOnly {
                            Button { change { $0.wifiConnectSsid = ""; $0.wifiConnectBssid = "" } } label: { Image(systemName: "xmark.circle") }
                                .accessibilityLabel(ProductText.string("btn_delete"))
                        }
                    }
                } else {
                    Text(sensors.network.map { ProductText.string("guest_tpl_wifi_now_connected",$0.ssid) } ?? ProductText.string("automation_wifi_not_connected"))
                        .font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    if !readOnly {
                        Button(ProductText.string("automation_wifi_use_current")) {
                            if let current = sensors.network { change { $0.wifiConnectSsid = current.ssid; $0.wifiConnectBssid = current.bssid } }
                        }.buttonStyle(SecondaryActionStyle()).disabled(sensors.network == nil)
                    }
                }
            } else {
                Text(ProductText.string("guest_tpl_wifi_list_label")).font(.headline)
                ForEach(networkNames, id: \.self) { name in
                    HStack {
                        Text(name.isEmpty ? "—" : name); Spacer()
                        if !readOnly {
                            Button {
                                let removed = Set(networkGroups[name] ?? [])
                                change {
                                    $0.wifiBssids = t.wifiBssids.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
                                    $0.wifiSsids = t.wifiSsids.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
                                }
                            } label: { Image(systemName: "xmark.circle") }.accessibilityLabel(ProductText.string("btn_delete"))
                        }
                    }
                }
                Text("Сканирование Wi-Fi сетей вокруг недоступно в iOS.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                if !t.wifiBssids.isEmpty {
                    let minimum = readOnly ? max(1,t.ownerMinMatch ?? t.wifiMinMatch) : 1
                    let maximum = max(minimum,t.wifiBssids.count)
                    Text(ProductText.string("guest_tpl_wifi_threshold_status_exact",min(maximum,max(minimum,t.wifiMinMatch)),t.wifiBssids.count))
                    Slider(value: Binding(get: { Double(min(maximum,max(minimum,t.wifiMinMatch))) }, set: { v in change { $0.wifiMinMatch = Int(v) } }), in: Double(minimum)...Double(max(minimum+1,maximum)),step: 1)
                        .disabled(minimum == maximum)
                }
            }
        }.onAppear { sensors.refreshNetwork() }
    }
}

private struct AutomationTimeFields: View {
    let template: AutomationTemplate
    let readOnly: Bool
    let save: ([AutomationTimeEntry]) -> Void
    private var all: Bool { template.combineMode == "all" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ProductText.string(all ? "automation_time_hint_interval" : "automation_time_hint_exact")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            ForEach(template.timeEntries.indices, id: \.self) { index in
                VStack(spacing: 8) {
                    HStack {
                        DatePicker("", selection: time(index, end: false), displayedComponents: .hourAndMinute).labelsHidden().environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        if all { Text("–"); DatePicker("", selection: time(index,end: true), displayedComponents: .hourAndMinute).labelsHidden().environment(\.timeZone, TimeZone(secondsFromGMT: 0)!) }
                        Spacer(minLength: 0)
                        if !readOnly {
                            Button(role: .destructive) { var rows = template.timeEntries; rows.remove(at: index); save(rows) } label: { Image(systemName: "xmark") }
                                .accessibilityLabel(ProductText.string("btn_delete"))
                        }
                    }
                    HStack(spacing: 4) {
                        ForEach([2,3,4,5,6,7,1], id: \.self) { day in
                            Button {
                                var rows = template.timeEntries
                                if rows[index].weekdays.contains(day) { rows[index].weekdays.remove(day) } else { rows[index].weekdays.insert(day) }
                                save(rows)
                            } label: {
                                Text(dayName(day)).font(.caption.weight(.semibold)).frame(maxWidth: .infinity,minHeight: 36)
                                    .background(template.timeEntries[index].weekdays.contains(day) ? AppPalette.secondary : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }.disabled(readOnly)
            }
            if !readOnly {
                Button(ProductText.string(all ? "automation_time_add_interval" : "automation_time_add_time")) {
                    save(template.timeEntries + [AutomationTimeEntry(weekdays:[2,3,4,5,6],fromMin:480,toMin:all ? 600:480)])
                }.buttonStyle(SecondaryActionStyle())
            }
        }
    }
    private func time(_ index: Int, end: Bool) -> Binding<Date> {
        Binding(get: {
            let minute = end ? template.timeEntries[index].toMin : template.timeEntries[index].fromMin
            return Date(timeIntervalSince1970: Double(minute*60))
        }, set: { date in
            var clock = Calendar(identifier: .gregorian); clock.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = clock.dateComponents([.hour,.minute],from: date)
            let minute = (components.hour ?? 0)*60+(components.minute ?? 0)
            var rows = template.timeEntries
            if end { rows[index].toMin = minute } else { rows[index].fromMin = minute; if !all { rows[index].toMin = minute } }
            save(rows)
        })
    }
    private func dayName(_ day: Int) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: UserDefaults.standard.string(forKey:"entrixy.language") ?? Locale.current.identifier)
        return formatter.shortWeekdaySymbols[day-1]
    }
}

private struct AutomationCodeSetup: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let close: () -> Void
    @State private var code = ""
    @State private var repeated = ""
    @State private var working = false
    @State private var message: String?
    var body: some View {
        AppDialogSurface {
            VStack(alignment:.leading,spacing:16) {
                Text(ProductText.string("code_title")).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Text(ProductText.string("code_setup_hint")).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                field(ProductText.string("code_field"),value:$code)
                field(ProductText.string("code_field_repeat"),value:$repeated)
                Text(ProductText.string("code_forgot_warning")).font(.footnote).foregroundStyle(AppPalette.destructive)
                if let message { Text(message).font(.footnote).foregroundStyle(AppPalette.destructive) }
                HStack(spacing:12) {
                    Button(ProductText.string("btn_cancel"),action:close).buttonStyle(SecondaryActionStyle())
                    Button {
                        guard !working, model.canManageGuestAccess else { return }
                        working = true
                        Task {
                            defer { working = false; code = ""; repeated = "" }
                            do { try await model.setActionCode(code); close() }
                            catch { message = "Не удалось сохранить код. Прежние данные сохранены." }
                        }
                    } label: { ActionButtonLabel(title:ProductText.string("btn_save"),busy:working) }
                        .buttonStyle(PrimaryActionStyle()).disabled(code != repeated || !(4...8).contains(code.count))
                }
            }.disabled(working || !model.canManageGuestAccess)
        }
        .onDisappear { code = ""; repeated = "" }
        .onChange(of:scenePhase) { if $0 != .active { code = ""; repeated = "" } }
    }
    private func field(_ title: String,value: Binding<String>) -> some View {
        AppField(title) {
            SecureField(title,text:value).keyboardType(.numberPad).textContentType(.password)
                .padding(14).background(Color(uiColor:.tertiarySystemFill),in:RoundedRectangle(cornerRadius:12))
                .onChange(of:value.wrappedValue) { value.wrappedValue = String($0.filter { $0.isASCII && $0.isNumber }.prefix(8)) }
        }
    }
}
