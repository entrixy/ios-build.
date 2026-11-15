#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import PhotosUI

// Approval-only native component catalog. No AppModel, identities, network or commands.
struct NativeDesignCatalog: View {
    static var requestedPage: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--native-design"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    private let page: String
    @State private var dialog: String?
    @State private var name = ""
    @State private var code = ""
    @State private var repeatedCode = ""
    @State private var confirmation = true
    @State private var biometric = false
    @State private var choice = 1
    @State private var mainTab = 1
    @State private var radius = 100.0
    @State private var date = Date(timeIntervalSince1970: 1_794_729_600)
    @State private var photo: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var message: String?
    init(page: String) { self.page = page }
    private let ink = Color(red: 27/255, green: 29/255, blue: 59/255)
    private let red = Color(red: 186/255, green: 26/255, blue: 26/255)
    private var title: String {
        switch page {
        case "buttons": return "Кнопки"
        case "fields": return "Поля и переключатели"
        case "rows": return "Списки и разделители"
        case "objects": return "Карточки объектов"
        case "journal": return "Журнал"
        case "navigation": return "Навигация"
        case "confirm": return "Подтверждение"
        case "delete": return "Удаление"
        case "code": return "Код Entrixy"
        case "avatar": return "Картинка объекта"
        case "selectors": return "Выбор и сроки"
        default: return "Дизайн-код iOS"
        }
    }
    var body: some View {
        Group {
            if page == "navigation" {
                TabView(selection: $mainTab) {
                    NavigationStack {
                        VStack { objectCard(online: true); Spacer() }.padding(20)
                            .background(Color(uiColor: .systemGroupedBackground))
                            .navigationTitle("Управление")
                    }.tabItem { Label("Управление", image: "tab-control") }.tag(0)
                    catalogScreen.tabItem { Label("Настройки", image: "tab-settings") }.tag(1)
                    NavigationStack {
                        Text("Ключи, выданные гостям").navigationTitle("Гости")
                    }.tabItem { Label("Гости", image: "tab-guests") }.tag(2)
                    NavigationStack {
                        VStack { journal; Spacer() }.padding(20)
                            .background(Color(uiColor: .systemGroupedBackground))
                            .navigationTitle("Журнал")
                    }.tabItem { Label("Журнал", image: "tab-journal") }.tag(3)
                }
            } else {
                catalogScreen
            }
        }.tint(ink).preferredColorScheme(.light)
    }
    private var catalogScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if page == "buttons" { buttons }
                    else if page == "fields" { fields }
                    else if page == "rows" { rows }
                    else if page == "objects" { objects }
                    else if page == "journal" { journal }
                    else if page == "navigation" { navigation }
                    else if page == "avatar" { avatar }
                    else if page == "selectors" { selectors }
                    else {
                        Text("Ворота во двор").font(.title2.bold())
                        objectCard(online: true)
                        action("Показать окно") { dialog = page }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("ДИЗАЙН-КОД · НА УТВЕРЖДЕНИЕ").font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(10).background(.background)
            }
            .overlay { if let dialog { dialogOverlay(dialog) } }
        }
        .tint(ink)
        .preferredColorScheme(.light)
        .task {
            if ["confirm", "delete", "code"].contains(page) { dialog = page }
            let status: [String: Any] = ["ready": true, "page": page, "native_design": true, "network_requests": 0, "command_frames": 0]
            if let data = try? JSONSerialization.data(withJSONObject: status) {
                let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("native-design-status.json")
                try? data.write(to: path, options: .atomic)
            }
        }
        .onChange(of: photo) { item in
            Task { imageData = try? await item?.loadTransferable(type: Data.self) }
        }
    }
    private func action(_ text: String, kind: Int = 0, disabled: Bool = false, perform: @escaping () -> Void = {}) -> some View {
        Button(action: perform) { Text(text).font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 48) }
            .buttonStyle(CatalogButtonStyle(kind: kind)).disabled(disabled)
    }
    private func heading(_ text: String) -> some View { Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content).padding(.horizontal, 16).background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
    private func field(_ label: String, placeholder: String, secure: Bool = false, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.weight(.semibold))
            Group {
                if secure { SecureField(placeholder, text: binding).keyboardType(.numberPad) }
                else { TextField(placeholder, text: binding) }
            }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
        }
    }
    private var buttons: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Единые роли · высота от 48 pt")
            action("Добавить сервер") { message = "Основное действие в каталоге" }
            action("Обновить данные", kind: 1)
            action("Отмена", kind: 1)
            action("Удалить объект", kind: 2)
            action("Недоступна", disabled: true)
            heading("Два равных действия")
            HStack(spacing: 12) { action("Позвонить"); action("Отказать", kind: 2) }
            HStack(spacing: 12) { action("Отмена", kind: 1); action("Сохранить") }
            HStack { ProgressView(); Text("Сохранение…") }.frame(maxWidth: .infinity, minHeight: 48).background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 20) {
            field("Название объекта", placeholder: "Ворота во двор", binding: $name)
            field("Код Entrixy", placeholder: "От 4 до 8 цифр", secure: true, binding: $code)
            panel {
                Toggle("Подтверждать нажатие", isOn: $confirmation).padding(.vertical, 14)
                Divider()
                Toggle("Вход с биометрией", isOn: $biometric).padding(.vertical, 14)
            }
            Picker("Подтверждение личности", selection: $choice) {
                Text("Без защиты").tag(0); Text("Код").tag(1); Text("Биометрия").tag(2)
            }.pickerStyle(.segmented)
            Text("Ошибка показывается рядом с полем.").font(.footnote).foregroundStyle(red)
        }
    }
    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(key).foregroundStyle(.secondary); Spacer(minLength: 12); Text(value).multilineTextAlignment(.trailing) }.font(.subheadline).padding(.vertical, 16)
    }
    private var rows: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Полученный ключ")
            panel {
                row("Сервер", "home.example"); Divider()
                row("Объектов", "2"); Divider()
                row("Состояние", "На связи"); Divider()
                row("Обновлено", "Сегодня, 12:30")
            }
            action("Обновить данные", kind: 1)
            action("Удалить ключ с iPhone", kind: 2)
            Text("Общие границы разделителей. Кнопки без дополнительных плашек.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func objectCard(online: Bool, status: String? = nil) -> some View {
        Button {
            message = online ? "Каталог: команда не отправлялась" : "Контроллер не в сети"
        } label: {
            HStack(spacing: 14) {
                Image("object-4").resizable().scaledToFit().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ворота во двор").font(.headline)
                    Text(status ?? (online ? "Контроллер в сети" : "Контроллер не в сети")).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private var objects: some View {
        VStack(alignment: .leading, spacing: 20) {
            objectCard(online: true); objectCard(online: false)
            objectCard(online: true, status: "Запрос отправлен · ожидаем ответ")
            Text("Нажимается вся карточка. Отказ — без модального окна.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var journal: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                journalAction("Поделиться", symbol: "square.and.arrow.up", kind: 1)
                journalAction("Копировать", symbol: "doc.on.doc", kind: 1)
                journalAction("Очистить", symbol: "trash", kind: 2)
            }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .trailing, spacing: 8) { Text("12:30:00").monospacedDigit(); Text("15 ноября").font(.caption).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 6) { Text("Я").foregroundStyle(.secondary); Text("Ворота во двор").font(.headline); Text("Контроллер принял команду").foregroundStyle(.secondary) }
            }.font(.subheadline)
            Divider()
            Text("Демонстрационная запись каталога").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func journalAction(_ title: String, symbol: String, kind: Int) -> some View {
        Button { message = "Каталог: \(title.lowercased())" } label: {
            VStack(spacing: 8) { Image(systemName: symbol).font(.title3); Text(title).font(.system(size: 12, weight: .medium)) }.frame(maxWidth: .infinity, minHeight: 64)
        }.buttonStyle(CatalogButtonStyle(kind: kind))
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { BrandLogo(); Text("Настройки").font(.title2.bold()); Spacer() }
            Picker("Раздел настроек", selection: $choice) {
                Text("Объекты").tag(0); Text("Ключи").tag(1); Text("Звуки").tag(2); Text("Система").tag(3)
            }.pickerStyle(.segmented)
            Text("Вкладки настроек повторяют Android.").font(.footnote).foregroundStyle(.secondary)
            panel { NavigationLink("Полученный ключ") { Text("Содержимое ключа").navigationTitle("Полученный ключ").navigationBarTitleDisplayMode(.inline) }.padding(.vertical, 18) }
            Text("Основные разделы переключаются нижней панелью. Она остаётся у нижнего края экрана при прокрутке.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var avatar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                if let imageData, let image = UIImage(data: imageData) { Image(uiImage: image).resizable().scaledToFit() }
                else { Image("object-4").resizable().scaledToFit() }
            }.frame(width: 110, height: 110).padding(12).background(.background, in: RoundedRectangle(cornerRadius: 16))
            PhotosPicker(selection: $photo, matching: .images) {
                Text("Загрузить свою картинку").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(CatalogButtonStyle(kind: 1))
            action("Удалить свою картинку", kind: 1) { imageData = nil; photo = nil }
            heading("Или выбрать готовый значок")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                ForEach(1...8, id: \.self) { index in
                    Button { message = "Выбран значок \(index)" } label: { Image("object-\(index)").resizable().scaledToFit().frame(height: 54).padding(8) }.buttonStyle(.plain)
                }
            }
        }
    }
    private var selectors: some View {
        VStack(alignment: .leading, spacing: 20) {
            DatePicker("Действует до", selection: $date, displayedComponents: .date)
            DatePicker("Время начала", selection: $date, displayedComponents: .hourAndMinute)
            Text("Радиус: \(Int(radius)) м").font(.subheadline.weight(.semibold))
            Slider(value: $radius, in: 50...500, step: 10)
            Picker("Сочетание условий", selection: $choice) { Text("Любое").tag(0); Text("Все условия").tag(1) }.pickerStyle(.segmented)
            field("Комментарий", placeholder: "Текст сообщения", binding: $name)
            Text("Доступ действует").font(.caption).padding(10).background(Color(uiColor: .systemGray5), in: Capsule())
        }
    }
    private func dialogOverlay(_ kind: String) -> some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text(kind == "delete" ? "Удалить объект?" : (kind == "code" ? "Код Entrixy" : "Ворота во двор")).font(.title3.bold())
                    if kind == "code" {
                        Text("От 4 до 8 цифр. Не используйте код разблокировки телефона.").font(.subheadline)
                        field("Код", placeholder: "Введите код", secure: true, binding: $code)
                        field("Повторите код", placeholder: "Повторите код", secure: true, binding: $repeatedCode)
                        Text("Забытый код восстановить нельзя. Потребуется восстановить ключи из резервной копии.").font(.footnote).foregroundStyle(red)
                    } else {
                        Text(kind == "delete" ? "Гости потеряют доступ к этому объекту." : "Подтвердите открытие.").font(.body)
                    }
                    HStack(spacing: 12) {
                        action("Отмена", kind: 1) { dialog = nil }
                        action(kind == "delete" ? "Удалить" : (kind == "code" ? "Сохранить" : "Открыть"), kind: kind == "delete" ? 2 : 0) {
                            if kind == "code" && (code != repeatedCode || !(4...8).contains(code.count)) { message = "Проверьте совпадение кода" }
                            else { dialog = nil; message = "Каталог: действие не выполнялось" }
                        }
                    }
                }.padding(24).frame(width: min(proxy.size.width - 32, 420)).background(.background, in: RoundedRectangle(cornerRadius: 20))
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
private struct CatalogButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    let kind: Int
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(!enabled ? Color.secondary : (kind == 1 ? Color(red: 27/255, green: 29/255, blue: 59/255) : .white))
            .background(!enabled ? Color(uiColor: .systemGray5) : (kind == 2 ? Color(red: 186/255, green: 26/255, blue: 26/255) : (kind == 1 ? Color(red: 226/255, green: 227/255, blue: 237/255) : Color(red: 27/255, green: 29/255, blue: 59/255))), in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
#endif
