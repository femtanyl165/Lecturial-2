import SwiftUI
import UserNotifications
import CoreText
import WidgetKit

struct Lesson: Codable, Identifiable {
    var id: String { [date, start, title, room].joined(separator: "|") }
    let date: String
    let start: String
    let end: String
    let title: String
    let room: String
    let teacher: String
    var type: String? = nil
    var address: String? = nil
    var comment: String? = nil
    var onlineURL: String? = nil
}

actor ScheduleAPI {
    let base = URL(string: "https://schedule.siriusuniversity.ru/")!
    var session = URLSession(configuration: .ephemeral)
    func capture(_ pattern: String, _ text: String) throws -> String {
        let r = try NSRegularExpression(pattern: pattern)
        guard let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(m.range(at: 1), in: text) else { throw URLError(.cannotParseResponse) }
        return String(text[range])
    }
    func httpStatus(_ response: URLResponse) -> Int { (response as? HTTPURLResponse)?.statusCode ?? 0 }
    func request(_ req: URLRequest) async throws -> Data {
        var request = req
        request.setValue("Lecturial/1.0 (iOS; schedule client)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NSError(domain: "Расписание", code: httpStatus(response), userInfo: [NSLocalizedDescriptionKey: "Сервер вернул HTTP \(httpStatus(response)). Попробуйте позже."]) }
        return data
    }
    func fetch(group: String, week: Date) async throws -> [Lesson] {
        var failure: Error = URLError(.unknown)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            session.invalidateAndCancel()
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: config)
            do { return try await fetchOnce(group: group.trimmingCharacters(in: .whitespacesAndNewlines), week: week) }
            catch {
                failure = error
                let code = (error as NSError).code
                if error is CancellationError { throw error }
                if (error as NSError).domain == "Расписание", ![408,419,429,500,502,503,504].contains(code) { throw error }
                if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) }
            }
        }
        throw failure
    }
    func fetchOnce(group: String, week: Date) async throws -> [Lesson] {
        let page = group.hasPrefix("teacher:") ? base.appendingPathComponent("teacher") : (group.hasPrefix("classroom:") ? base.appendingPathComponent("classroom") : base)
        let html = String(decoding: try await request(URLRequest(url: page)), as: UTF8.self)
        var initial = try capture("wire:initial-data=\"([^\"]+)\"", html)
        for (a,b) in [("&quot;", "\""), ("&#039;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] { initial = initial.replacingOccurrences(of: a, with: b) }
        let root = try JSONSerialization.jsonObject(with: Data(initial.utf8)) as? [String: Any] ?? [:]
        guard let fingerprint = root["fingerprint"] as? [String: Any], var memo = root["serverMemo"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        var rawMemo = try WireJSON.field("serverMemo", in: initial)
        let rawFingerprint = try WireJSON.field("fingerprint", in: initial)
        let token = try capture("window\\.livewire_token\\s*=\\s*'([^']+)'", html)
        func call(_ method: String, _ params: [String]) async throws {
            let name = fingerprint["name"] as? String ?? "main-grid"
            var req = URLRequest(url: base.appendingPathComponent("livewire/message/" + name))
            req.httpMethod = "POST"
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
            req.setValue(token, forHTTPHeaderField: "X-CSRF-TOKEN")
            req.setValue("true", forHTTPHeaderField: "X-Livewire")
            req.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
            let updates: [[String: Any]] = [["type": "callMethod", "payload": ["id": UUID().uuidString, "method": method, "params": params]]]
            let updateJSON = String(decoding: try JSONSerialization.data(withJSONObject: updates, options: [.withoutEscapingSlashes]), as: UTF8.self)
            // Livewire verifies the original memo checksum; retain its JSON key order.
            req.httpBody = Data(("{\"fingerprint\":" + rawFingerprint + ",\"serverMemo\":" + rawMemo + ",\"updates\":" + updateJSON + "}").utf8)
            let responseData = try await request(req)
            let responseText = String(decoding: responseData, as: UTF8.self)
            let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            rawMemo = try WireJSON.merge(rawMemo, WireJSON.field("serverMemo", in: responseText))
            guard let patch = response?["serverMemo"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
            for (key,value) in patch {
                if key == "data", let values = value as? [String: Any] { var old = memo[key] as? [String: Any] ?? [:]; old.merge(values) { _,new in new }; memo[key] = old } else { memo[key] = value }
            }
        }
        try await call("set", [group.replacingOccurrences(of: "teacher:", with: "").replacingOccurrences(of: "classroom:", with: "")])
        let formatter = DateFormatter(); formatter.dateFormat = "dd.MM.yyyy"; formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let data = memo["data"] as? [String: Any], let rawDate = data["date"] as? String, let date = formatter.date(from: rawDate) else { throw URLError(.cannotParseResponse) }
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = .current
        let source = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        let target = calendar.dateInterval(of: .weekOfYear, for: week)!.start
        let offset = calendar.dateComponents([.day], from: source, to: target).day! / 7
        guard abs(offset) <= 104 else { throw URLError(.badURL) }
        for _ in 0..<abs(offset) { try await call(offset > 0 ? "addWeek" : "minusWeek", []) }
        let events = (memo["data"] as? [String: Any])?["events"] as? [String: Any] ?? [:]
        return events.values.flatMap { $0 as? [[String: Any]] ?? [] }.compactMap { raw in
            guard let title = raw["discipline"] as? String, let date = raw["date"] as? String else { return nil }
            let teachers = raw["teachers"] as? [String: [String: Any]] ?? [:]
            return Lesson(date: date, start: raw["startTime"] as? String ?? "", end: raw["endTime"] as? String ?? "", title: title, room: raw["classroom"] as? String ?? "", teacher: teachers.values.compactMap { $0["fio"] as? String }.sorted().joined(separator: ", "), type: raw["groupType"] as? String, address: raw["address"] as? String, comment: raw["comment"] as? String, onlineURL: raw["urlOnline"] as? String)
        }.filter { group.hasPrefix("teacher:") || group.hasPrefix("classroom:") || !isExtracurricular($0) }.sorted { $0.start < $1.start }
    }
}

@MainActor final class ScheduleStore: ObservableObject {
    @Published var lessons: [Lesson] = []
    @Published var loading = false
    @Published var message = ""
    let api = ScheduleAPI()
    func load(group: String, week: Date) async {
        guard !loading, !group.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        loading = true; defer { loading = false }
        let key = "week-" + group + "-" + String(Int(week.timeIntervalSince1970 / 86400))
        lessons = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([Lesson].self, from: $0) } ?? []
        message = lessons.isEmpty ? "" : "Сохранённое расписание"
        do { lessons = try await api.fetch(group: group, week: week); UserDefaults.standard.set(try JSONEncoder().encode(lessons), forKey: key); await LessonAlertService.update(lessons); await SystemFeatures.update(lessons, group: group); await PhoneCalendar.shared.sync(); await OutlookSync.shared.automatic(lessons: lessons, group: group, week: week); message = lessons.isEmpty ? "На эту неделю занятий нет" : "Обновлено" }
        catch { message = "Не удалось обновить расписание: " + error.localizedDescription }
    }
}

@main struct LecturialApp: App {
    init() {
        if let url = Bundle.main.url(forResource: "manrope_regular", withExtension: "ttf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }
    var body: some Scene { WindowGroup { AppRootView() } }
}
struct AppRootView: View {
    @AppStorage("setupFinished") private var setupFinished = false
    @AppStorage("theme") private var theme = "sirius"
    @AppStorage("customAccent") private var customAccent = "B7C7FF"
    @AppStorage("dark") private var dark = true
    @State private var selected = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let accent = themeColor(theme, custom: customAccent)
        TabView(selection: $selected) {
            ScheduleView().tag(0).toolbar(.hidden, for: .tabBar)
            PlansView().tag(1).toolbar(.hidden, for: .tabBar)
            ExpressiveStudyView().tag(3).toolbar(.hidden, for: .tabBar)
            AppearanceView().tag(2).toolbar(.hidden, for: .tabBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                navItem(0, "Расписание", "calendar", accent)
                navItem(1, "Планы", "checklist", accent)
                navItem(3, "Учёба", "graduationcap", accent)
                navItem(2, "Настройки", "gearshape", accent)
            }.padding(.horizontal, 12).padding(.vertical, 10)
            .background(dark ? Color(hex: 0x20222B) : Color(hex: 0xEBEDF7))
        }.tint(accent).preferredColorScheme(isPaperTheme(theme) ? .light : (dark ? .dark : .light)).onChange(of:scenePhase) { _,phase in if phase == .active, AccountStore.shared.browser.url?.host == "lks.siriusuniversity.ru" { Task { await AccountStore.shared.refresh() } } }.fullScreenCover(isPresented: Binding(get: { !setupFinished },set: { if !$0 { setupFinished = true } })) { FirstSetupView() }
    }
    func navItem(_ index: Int, _ title: String, _ symbol: String, _ accent: Color) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) { selected = index }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20, weight: selected == index ? .semibold : .regular)).frame(width: 64, height: 32).background(selected == index ? accent.opacity(0.2) : .clear, in: Capsule())
                Text(title).font(.caption.weight(selected == index ? .semibold : .medium))
            }.foregroundStyle(selected == index ? accent : (dark ? Color(hex: 0xBFC1CC) : Color(hex: 0x535560))).frame(maxWidth: .infinity).frame(minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected == index ? [.isSelected] : [])
    }
}
struct ScheduleView: View {
    @AppStorage("scheduleLayout") private var layout = "feed"
    @State private var selectedDay = max(0, (Calendar(identifier: .iso8601).component(.weekday, from: Date()) + 5) % 7)
    @AppStorage("customAccent") private var customAccent = "B7C7FF"
    @AppStorage("theme") private var theme = "sirius"
    @AppStorage("titleSize") private var titleSize = 16.0
    @AppStorage("spacing") private var spacing = 20.0
    @AppStorage("radius") private var radius = 24.0
    @AppStorage("showRoom") private var showRoom = true
    @AppStorage("showTeacher") private var showTeacher = true
    @AppStorage("showEnd") private var showEnd = true
    @AppStorage("wrap") private var wrap = true
    @AppStorage("opacity") private var opacity = 0.78
    @AppStorage("background") private var background = "classic"
    @StateObject private var store = ScheduleStore()
    @AppStorage("group") private var group = ""
    @AppStorage("dark") private var dark = true
    @State private var week = Calendar(identifier: .iso8601).dateInterval(of: .weekOfYear, for: Date())!.start
    @State private var settings = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button { shift(-7) } label: { Image(systemName: "chevron.left") }.disabled(store.loading)
                        Spacer()
                        Text(week, format: .dateTime.day().month().year())
                        Spacer()
                        Button { shift(7) } label: { Image(systemName: "chevron.right") }.disabled(store.loading)
                    }.buttonStyle(.borderless)
                    if layout == "days" {
                        HStack(spacing: 4) { ForEach(0..<7, id: \.self) { index in
                            Button { selectedDay = index } label: { Text(Calendar.current.date(byAdding: .day,value:index,to:week)!, format:.dateTime.day()).frame(maxWidth:.infinity).padding(.vertical,10).background(selectedDay == index ? accent.opacity(0.25) : .clear,in:Capsule()) }.buttonStyle(.plain)
                        } }
                    }
                    NavigationLink("План дня") { DayPlannerView() }
                    Text(group.isEmpty ? "Укажите учебную группу в настройках" : group).font(.headline)
                    if store.loading { ProgressView("Загрузка…") }
                    if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(layout == "days" ? [selectedDay] : Array(0..<7), id: \.self) { offset in
                    let date = Calendar.current.date(byAdding: .day, value: offset, to: week)!
                    let items = store.lessons.filter { $0.date == dateKey(date) && (group.hasPrefix("teacher:") || group.hasPrefix("classroom:") || !isExtracurricular($0)) }
                    Section {
                        if items.isEmpty { Text(store.message.hasPrefix("Не удалось") ? "Нет сохранённых данных на этот день" : (store.loading ? "Загрузка…" : "Нет занятий")).foregroundStyle(.secondary) }
                        ForEach(items) { lesson in
                            ExpressiveLessonCard(lesson: lesson, accent: accent, dark: isPaperTheme(theme) ? false : dark, titleSize: titleSize, radius: radius, opacity: opacity, showRoom: showRoom, showTeacher: showTeacher, showEnd: showEnd, wrap: wrap)
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: spacing / 2, leading: 16, bottom: spacing / 2, trailing: 16))
                        }
                    } header: {
                        HStack { Text(date.formatted(.dateTime.weekday(.wide).day().month())); if Calendar.current.isDateInToday(date) { Text("Сегодня").font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 5).background(accent.opacity(0.18), in: Capsule()) } }.font(.headline).foregroundStyle(accent).textCase(nil).padding(.vertical, 8)
                    }
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                guard layout == "days", abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < 0 { if selectedDay < 6 { selectedDay += 1 } else { shift(7); selectedDay = 0 } }
                else { if selectedDay > 0 { selectedDay -= 1 } else { shift(-7); selectedDay = 6 } }
            })
            .listRowBackground(Color.clear)
            .scrollContentBackground(.hidden)
            .background { ScheduleBackground(style: background, accent: accent, dark: dark) }
            .navigationTitle(group.isEmpty ? "Lecturial" : group)
            .safeAreaInset(edge: .bottom) { if !store.lessons.isEmpty { Text("За неделю: \(store.lessons.count) занятий · \(Set(store.lessons.map(\.title)).count) предметов").font(.caption).padding(8).frame(maxWidth: .infinity).background(.ultraThinMaterial) } }
            .toolbar { Button { settings = true } label: { Image(systemName: "gearshape") } }
            .refreshable { await store.load(group: group, week: week) }
            .task { await store.load(group: group, week: week) }
            .task(id: group) { while !Task.isCancelled { await SystemFeatures.update(store.lessons, group: group); do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break } } }
            .sheet(isPresented: $settings, onDismiss: { Task { await store.load(group: group, week: week) } }) {
                NavigationStack { Form {
                    Section("Учёба") { NavigationLink("Найти группу, преподавателя, аудиторию") { TargetSearchView() }; TextField("Ключ расписания", text: $group).autocorrectionDisabled() }
                    Section {
                    HStack(spacing: 16) { Image("LecturialAvatar").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 16)); VStack(alignment: .leading) { Text("Lecturial 2").font(.headline); Text("Расписание Сириуса").foregroundStyle(.secondary) } }
                }
                Section("Оформление") { LayoutChooser(layout:$layout); Toggle("Тёмная тема", isOn: $dark) }
                    Section { Link("Расписание Сириуса", destination: URL(string: "https://schedule.siriusuniversity.ru/")!); Text("Неофициальное приложение университета «Сириус»").font(.caption) }
                }.navigationTitle("Настройки").toolbar { Button("Готово") { settings = false } } }
            }
        }.preferredColorScheme(isPaperTheme(theme) ? .light : (dark ? .dark : .light)).tint(accent)
    }
    var accent: Color { themeColor(theme, custom: customAccent) }
    func shift(_ days: Int) { week = Calendar.current.date(byAdding: .day, value: days, to: week)!; Task { await store.load(group: group, week: week) } }
    func dateKey(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"; return f.string(from: date) }
}

struct StudyTask: Codable, Identifiable {
    var id = UUID()
    var title: String
    var due: Date
    var completed = false
    var note: String?
    var recurrence: String?
    var kind: String?
}
@MainActor final class PlansStore: ObservableObject {
    @Published var tasks: [StudyTask] = []
    @Published var error = ""
    init() { if let data = UserDefaults.standard.data(forKey: "plans") { tasks = (try? JSONDecoder().decode([StudyTask].self, from: data)) ?? [] } }
    func save() {
        do { let data = try JSONEncoder().encode(tasks); UserDefaults.standard.set(data, forKey: "plans"); UserDefaults(suiteName: "group.com.rassvet.lecturial2")?.set(data, forKey: "plans"); WidgetCenter.shared.reloadAllTimelines() }
        catch { self.error = error.localizedDescription }
    }
    func add(title: String, due: Date, remind: Bool) async {
        let task = StudyTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines), due: due)
        guard !task.title.isEmpty else { return }
        tasks.append(task); tasks.sort { $0.due < $1.due }; save()
        guard remind else { return }
        do {
            let center = UNUserNotificationCenter.current()
            guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { error = "Уведомления отключены. Разрешите их в настройках iOS."; return }
            let content = UNMutableNotificationContent(); content.title = "Дедлайн"; content.body = task.title; content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: due), repeats: false)
            try await center.add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger))
        } catch { self.error = error.localizedDescription }
    }
    func toggle(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        if !tasks[i].completed, let recurrence = tasks[i].recurrence, recurrence != "none" {
            let components: [String:Calendar.Component] = ["daily":.day,"weekly":.weekOfYear,"monthly":.month,"yearly":.year]
            if let component = components[recurrence] { tasks[i].due = Calendar.current.date(byAdding: component, value: 1, to: tasks[i].due) ?? tasks[i].due }
        } else { tasks[i].completed.toggle() }
        save()
        Task { await reschedule(tasks[i]) }
    }
    func reschedule(_ task: StudyTask) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
        guard !task.completed, task.due > Date(), await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent(); content.title = task.title; content.body = task.note ?? "Дедлайн"; content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, task.due.timeIntervalSinceNow), repeats: false)
        do { try await center.add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger)) } catch { self.error = error.localizedDescription }
    }
    func delete(_ offsets: IndexSet) {
        let ids = offsets.map { tasks[$0].id.uuidString }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        tasks.remove(atOffsets: offsets); save()
    }
}
struct PlansView: View {
    @StateObject private var store = PlansStore()
    @State private var title = ""
    @State private var due = Date().addingTimeInterval(3600)
    @State private var remind = true
    @State private var filter = "active"
    @State private var editing: StudyTask?
    var body: some View {
        NavigationStack {
            List {
                Section { NavigationLink("План дня") { DayPlannerView() } }
                Section("Новый план") {
                    TextField("Задание или экзамен", text: $title)
                    DatePicker("Дедлайн", selection: $due, in: Date()...)
                    Toggle("Напомнить в срок", isOn: $remind)
                    Button("Добавить") { let text = title; title = ""; Task { await store.add(title: text, due: due, remind: remind) } }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !store.error.isEmpty { Text(store.error).foregroundStyle(.red) }
                Section {
                    Picker("Показать", selection: $filter) { Text("Активные").tag("active"); Text("Сегодня").tag("today"); Text("Готовые").tag("done"); Text("Все").tag("all") }.pickerStyle(.segmented)
                    Text("Активных: \(store.tasks.filter { !$0.completed }.count) · Просрочено: \(store.tasks.filter { !$0.completed && $0.due < Date() }.count)").font(.caption)
                }
                Section("Планы и дедлайны") {
                    if store.tasks.isEmpty { Text("Пока нет планов").foregroundStyle(.secondary) }
                    ForEach(store.tasks.filter { task in filter == "all" || (filter == "done" ? task.completed : (!task.completed && (filter != "today" || Calendar.current.isDateInToday(task.due)))) }) { task in
                        Button { store.toggle(task.id) } label: {
                            HStack {
                                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(task.title).strikethrough(task.completed)
                                    Text(task.due, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(task.due < Date() && !task.completed ? .red : .secondary)
                                }
                            }
                        }.foregroundStyle(.primary)
                        .swipeActions(edge: .leading) { Button("Изменить") { editing = task }.tint(.blue) }
                        .swipeActions { Button("Удалить", role: .destructive) { if let i = store.tasks.firstIndex(where: { $0.id == task.id }) { store.delete(IndexSet(integer: i)) } } }
                    }
                }
            }.navigationTitle("Планы")
            .sheet(item: $editing) { task in PlanEditor(task: task) { updated in
                if let index = store.tasks.firstIndex(where: { $0.id == updated.id }) { store.tasks[index] = updated; store.save(); Task { await store.reschedule(updated) } }
                editing = nil
            } }
        }
    }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) }
}
func themeColor(_ name: String, custom: String = "B7C7FF") -> Color {
    if name == "custom", let value = UInt32(custom.replacingOccurrences(of: "#", with: ""), radix: 16) { return Color(hex: value) }
    let colors: [String: UInt32] = ["paper":0x2563EB,"mint":0x0B8A68,"lavender":0x6D4ED1,"midnight":0x3B5BDB,"espresso":0x8B5A3C,"sirius":0xB7C7FF,"ocean":0x6DD5ED,"forest":0x92FE9D,"sunset":0xFEB47B,"amethyst":0xB39DDB,"sakura":0xE9A0B4,"amber":0xFFC107,"graphite":0xBDC3C7,"neon":0x00E5FF,"fuchsia":0xFF80CC,"electric":0x80A0FF]
    return Color(hex: colors[name] ?? 0xB7C7FF)
}
struct ScheduleBackground: View {
    let style: String
    let accent: Color
    let dark: Bool
    @AppStorage("customAccent") private var customAccent = "B7C7FF"
    @AppStorage("gradientEnd") private var gradientEnd = "845EC2"
    @AppStorage("gradientAngle") private var gradientAngle = 135.0
    @AppStorage("liveActivities") private var liveActivities = false
    @AppStorage("lineDensity") private var density = 1.0
    @AppStorage("lineWeight") private var weight = 1.5
    @AppStorage("backgroundSpeed") private var speed = 0.5
    @AppStorage("backgroundIntensity") private var intensity = 0.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || speed == 0 || style == "classic")) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * speed * 0.2
            ZStack {
                (isPaperTheme(UserDefaults.standard.string(forKey:"theme") ?? "") ? paperBackground(UserDefaults.standard.string(forKey:"theme") ?? "") : (dark ? Color.black : Color(white: 0.96)))
                if style != "classic" { LinearGradient(colors: [accent.opacity(intensity * 0.4), .clear, Color(hex: UInt32(gradientEnd.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x845EC2).opacity(intensity * 0.3)], startPoint: UnitPoint(x: 0.5 - cos(gradientAngle * .pi / 180) * 0.5, y: 0.5 - sin(gradientAngle * .pi / 180) * 0.5), endPoint: UnitPoint(x: 0.5 + cos(gradientAngle * .pi / 180) * 0.5, y: 0.5 + sin(gradientAngle * .pi / 180) * 0.5)) }
                Canvas { context, size in
                    let count = max(12, Int(36 * density))
                    let ink = accent.opacity(intensity * (dark ? 0.6 : 0.8))
                    if style == "fingerprint" {
                        for line in 0..<count {
                            var path = Path()
                            let radius = Double(line + 1) * max(size.width, size.height) / Double(count)
                            for step in 0...240 {
                                let angle = Double(step) / 240 * .pi * 2
                                let r = radius * (1 + 0.08 * sin(angle * 3 + phase))
                                let point = CGPoint(x: size.width * 0.5 + cos(angle) * r * 0.65, y: size.height * 0.45 + sin(angle) * r)
                                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            }
                            context.stroke(path, with: .color(ink), lineWidth: weight)
                        }
                    } else if style == "maze" {
                        let cell = 28 / density
                        for row in 0...Int(size.height / cell) {
                            for column in 0...Int(size.width / cell) {
                                let x = Double(column) * cell, y = Double(row) * cell
                                var path = Path()
                                let flip = (row * 31 + column * 17 + row * column) % 7 < 3
                                path.move(to: CGPoint(x: x, y: flip ? y : y + cell))
                                path.addLine(to: CGPoint(x: x + cell, y: flip ? y + cell : y))
                                context.stroke(path, with: .color(ink), lineWidth: weight)
                            }
                        }
                    } else if style == "waves" || style == "topography" {
                        for line in 0..<count + 8 {
                            var path = Path()
                            for x in stride(from: 0.0, through: size.width + 5, by: 5.0) {
                                let base = Double(line - 4) * size.height / Double(count)
                                let y = base + (style == "waves" ? sin(x / 80 + phase + Double(line) * 0.15) * 25 : sin(x / 95 + Double(line) * 0.23 + phase) * 36 + cos(x / 48 - Double(line) * 0.17) * 14)
                                if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                            context.stroke(path, with: .color(ink), lineWidth: weight)
                        }
                    }
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}
struct AppearanceView: View {
    @AppStorage("scheduleLayout") private var layout = "feed"
    @AppStorage("theme") private var theme = "sirius"
    @AppStorage("dark") private var dark = true
    @AppStorage("background") private var background = "classic"
    @AppStorage("titleSize") private var titleSize = 16.0
    @AppStorage("spacing") private var spacing = 20.0
    @AppStorage("radius") private var radius = 24.0
    @AppStorage("opacity") private var opacity = 0.78
    @AppStorage("showRoom") private var room = true
    @AppStorage("showTeacher") private var teacher = true
    @AppStorage("showEnd") private var end = true
    @AppStorage("wrap") private var wrap = true
    @AppStorage("customAccent") private var customAccent = "B7C7FF"
    @AppStorage("gradientEnd") private var gradientEnd = "845EC2"
    @AppStorage("gradientAngle") private var gradientAngle = 135.0
    @AppStorage("liveActivities") private var liveActivities = false
    @AppStorage("lineDensity") private var density = 1.0
    @AppStorage("lineWeight") private var weight = 1.5
    @AppStorage("backgroundSpeed") private var speed = 0.5
    @AppStorage("backgroundIntensity") private var intensity = 0.6
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) { Image("LecturialAvatar").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 16)); VStack(alignment: .leading) { Text("Lecturial 2").font(.headline); Text("Расписание Сириуса").foregroundStyle(.secondary) } }
                }
                Section("Оформление") { LayoutChooser(layout:$layout)
                    Toggle("Тёмная тема", isOn: $dark)
                    Picker("Палитра", selection: $theme) {
                        ForEach(["sirius","ocean","forest","sunset","amethyst","sakura","amber","graphite","neon","fuchsia","electric","paper","mint","lavender","midnight","espresso","custom"], id: \.self) { name in Text(name.capitalized).foregroundStyle(themeColor(theme, custom: customAccent)).tag(name) }
                    }
                    .id("palette-" + theme)
                    Picker("Фон", selection: $background) {
                        Text("Классический").tag("classic"); Text("Тональный").tag("dynamic"); Text("Волны").tag("waves"); Text("Топография").tag("topography"); Text("Отпечаток").tag("fingerprint"); Text("Лабиринт").tag("maze")
                    }
                }
                Section("Собственные цвета") {
                    TextField("Акцент RRGGBB", text: $customAccent).autocorrectionDisabled()
                    TextField("Конец градиента RRGGBB", text: $gradientEnd).autocorrectionDisabled()
                    Text("Угол градиента: \(Int(gradientAngle))°"); Slider(value: $gradientAngle, in: 0...360)
                }
                Section("Настройки фона") {
                    ScheduleBackground(style: background, accent: themeColor(theme, custom: customAccent), dark: dark).frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 20)).listRowInsets(EdgeInsets())
                    Text("Плотность линий"); Slider(value: $density, in: 0.5...1.5)
                    Text("Толщина линий"); Slider(value: $weight, in: 1...5)
                    Text("Скорость анимации"); Slider(value: $speed, in: 0...1)
                    Text("Интенсивность"); Slider(value: $intensity, in: 0.1...1)
                }
                Section("Карточки расписания") {
                    Toggle("Аудитория", isOn: $room); Toggle("Преподаватель", isOn: $teacher); Toggle("Время окончания", isOn: $end); Toggle("Перенос названий", isOn: $wrap)
                    Text("Размер текста: \(Int(titleSize))"); Slider(value: $titleSize, in: 12...28, step: 1)
                    Text("Интервалы: \(Int(spacing))"); Slider(value: $spacing, in: 0...40, step: 1)
                    Text("Скругление: \(Int(radius))"); Slider(value: $radius, in: 0...36, step: 1)
                    Text("Непрозрачность"); Slider(value: $opacity, in: 0.2...1)
                    Button("Сбросить карточки") { titleSize = 16; spacing = 20; radius = 24; opacity = 0.78; room = true; teacher = true; end = true; wrap = true }
                }
                Section("Возможности") { Toggle("Live Activities", isOn: $liveActivities); NavigationLink("Поиск расписания") { TargetSearchView() }; NavigationLink("Аналитика сохранённых недель") { AnalyticsView() }; NavigationLink("Календари устройства / Google") { PhoneCalendarView() }; NavigationLink("Начальная настройка") { FirstSetupView() }; NavigationLink("Outlook") { OutlookView() }; NavigationLink("Экспорт календаря") { CalendarExportView() }; NavigationLink("Напоминания о занятиях") { LessonAlertsView() } }
                Section("О приложении") { Text("Lecturial 2 · iOS"); Text("Неофициальное приложение университета «Сириус»").font(.caption) }
            }.navigationTitle("Настройки")
        }.preferredColorScheme(isPaperTheme(theme) ? .light : (dark ? .dark : .light)).tint(themeColor(theme, custom: customAccent))
    }
}

// Ordered raw JSON fields prevent Foundation dictionary reordering from invalidating Livewire checksums.
enum WireJSON {
    static func fields(_ text: String) throws -> [(String, String)] {
        let bytes = Array(text.utf8)
        var i = 0
        func skip() { while i < bytes.count && [9,10,13,32].contains(bytes[i]) { i += 1 } }
        func stringEnd() throws {
            guard i < bytes.count && bytes[i] == 34 else { throw URLError(.cannotParseResponse) }
            i += 1
            while i < bytes.count {
                if bytes[i] == 92 { i += 2; continue }
                if bytes[i] == 34 { i += 1; return }
                i += 1
            }
            throw URLError(.cannotParseResponse)
        }
        skip(); guard i < bytes.count && bytes[i] == 123 else { throw URLError(.cannotParseResponse) }; i += 1
        var result: [(String,String)] = []
        while true {
            skip(); guard i < bytes.count else { throw URLError(.cannotParseResponse) }
            if bytes[i] == 125 { return result }
            let start = i; try stringEnd()
            let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<i]))
            skip(); guard i < bytes.count && bytes[i] == 58 else { throw URLError(.cannotParseResponse) }; i += 1; skip()
            let valueStart = i
            var depth = 0
            while i < bytes.count {
                let c = bytes[i]
                if c == 34 { try stringEnd(); continue }
                if depth == 0 && (c == 44 || c == 125) { break }
                if c == 123 || c == 91 { depth += 1 }
                if c == 125 || c == 93 { depth -= 1 }
                i += 1
            }
            result.append((key, String(decoding: bytes[valueStart..<i], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            skip(); if i < bytes.count && bytes[i] == 44 { i += 1 }
        }
    }
    static func field(_ key: String, in text: String) throws -> String {
        guard let value = try fields(text).first(where: { $0.0 == key })?.1 else { throw URLError(.cannotParseResponse) }; return value
    }
    static func merge(_ original: String, _ patch: String) throws -> String {
        var values = try fields(original)
        for (key, value) in try fields(patch) {
            if let index = values.firstIndex(where: { $0.0 == key }) {
                values[index].1 = key == "data" ? try merge(values[index].1, value) : value
            } else { values.append((key,value)) }
        }
        return "{" + (try values.map { key,value in String(decoding: try JSONEncoder().encode(key), as: UTF8.self) + ":" + value }).joined(separator: ",") + "}"
    }
}

extension Lesson {
    func timestamp(_ time: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Europe/Moscow"); f.dateFormat = "dd.MM.yyyy HH:mm"
        return f.date(from: date + " " + String(time.prefix(5)))
    }
    var begin: Date? { timestamp(start) }
    var finish: Date? { timestamp(end) }
}

struct PlanEditor: View {
    @State var task: StudyTask
    let save: (StudyTask) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack { Form {
            TextField("Название", text: $task.title)
            TextField("Заметка", text: Binding(get: { task.note ?? "" }, set: { task.note = $0 }), axis: .vertical)
            Picker("Тип", selection: Binding(get: { task.kind ?? "task" }, set: { task.kind = $0 })) { Text("Задача").tag("task"); Text("Цель").tag("goal"); Text("Дедлайн").tag("deadline"); Text("Событие").tag("event") }
            DatePicker("Срок", selection: $task.due)
            Picker("Повтор", selection: Binding(get: { task.recurrence ?? "none" }, set: { task.recurrence = $0 })) { Text("Нет").tag("none"); Text("Ежедневно").tag("daily"); Text("Еженедельно").tag("weekly"); Text("Ежемесячно").tag("monthly"); Text("Ежегодно").tag("yearly") }
            Toggle("Выполнено", isOn: $task.completed)
            Text("После выполнения повторяющийся план переносится на следующий срок.").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("Изменить план").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { save(task) }.disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        } }
    }
}

struct ExpressiveLessonCard: View {
    @ObservedObject private var account = AccountStore.shared
    let lesson: Lesson
    let accent: Color
    let dark: Bool
    let titleSize: Double
    let radius: Double
    let opacity: Double
    let showRoom: Bool
    let showTeacher: Bool
    let showEnd: Bool
    let wrap: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let active = (lesson.begin ?? .distantFuture) <= timeline.date && timeline.date < (lesson.finish ?? .distantPast)
            let lecture = (lesson.type ?? "").lowercased().contains("лек")
            let stripe = lecture ? Color(hex: 0x6DCBF0) : Color(hex: 0xE8BE50)
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center) { timeLabel; Spacer(minLength: 12); typeChip }
                    VStack(alignment: .leading, spacing: 8) { timeLabel; typeChip }
                }
                Text(lesson.title).font(.custom("Manrope", size: titleSize, relativeTo: .headline).weight(.semibold)).lineLimit(wrap ? nil : 1).foregroundStyle(dark ? Color(hex: 0xF4F4F5) : Color(hex: 0x191B23))
                if showRoom && !lesson.room.isEmpty { Label(cleanRoom(lesson.room), systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(dark ? Color(hex: 0xE2E2E9) : Color(hex: 0x363842)) }
                if let mark = account.snapshot.marks.filter({ sameSubject($0.discipline,lesson.title) && ($0.date == lesson.date || $0.date == isoDate(lesson)) }).min(by: { abs(timeMinutes($0.time) - timeMinutes(lesson.start)) < abs(timeMinutes($1.time) - timeMinutes(lesson.start)) }) {
                    HStack { if let grade = mark.grade { Text("Оценка: " + grade.formatted()).font(.caption.bold()) }; if let absent = mark.absent { Text(absent ? "Отсутствие" : "Присутствие").font(.caption) } }.foregroundStyle(accent)
                    if let topic = mark.topic,!topic.isEmpty { Text(topic).font(.subheadline) }
                    if let homework = mark.homework,!homework.isEmpty { Text("ДЗ: " + homework).font(.subheadline) }
                }
                if showTeacher && !lesson.teacher.isEmpty { Text(lesson.teacher).font(.subheadline).foregroundStyle(dark ? Color(hex: 0xBFC1CC) : Color(hex: 0x535560)) }
                if active, let end = lesson.finish, let start = lesson.begin {
                    Label("Сейчас · осталось \(max(1, Int(end.timeIntervalSince(timeline.date) / 60))) мин", systemImage: "clock.fill").font(.caption.bold()).foregroundStyle(accent)
                    ProgressView(value: timeline.date.timeIntervalSince(start), total: max(1, end.timeIntervalSince(start))).tint(accent)
                }
                if let comment = lesson.comment, !comment.isEmpty { Text(comment).font(.caption).foregroundStyle(.secondary) }
                if let raw = lesson.onlineURL, let url = URL(string: raw), ["https","http"].contains(url.scheme ?? "") { Link("Подключиться", destination: url).buttonStyle(.borderedProminent).buttonBorderShape(.capsule) }
            }
            .padding(.leading, 26).padding(.trailing, 20).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    (isPaperTheme(UserDefaults.standard.string(forKey:"theme") ?? "") ? Color.white : (dark ? Color(hex: 0x1D2029) : Color(hex: 0xF0F1FA))).opacity(max(0.92, opacity))
                    accent.opacity(active ? 0.12 : 0.035)
                }
            }
            .overlay(alignment: .leading) { Capsule().fill(active ? accent : stripe).frame(width: 3).padding(.leading, 12).padding(.vertical, 22) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { if active { RoundedRectangle(cornerRadius: radius).strokeBorder(accent.opacity(0.45), lineWidth: 1) } }
        }
    }
    var timeLabel: some View { Text(lesson.start + (showEnd ? " – " + lesson.end : "")).font(.system(.subheadline, design: .monospaced).weight(.medium)).foregroundStyle(accent) }
    @ViewBuilder var typeChip: some View { if let type = lesson.type, !type.isEmpty { Text(type).font(.caption.weight(.medium)).foregroundStyle(accent).padding(.horizontal, 12).padding(.vertical, 7).background(accent.opacity(dark ? 0.14 : 0.1), in: Capsule()).fixedSize(horizontal: false, vertical: true) } }
}

func isExtracurricular(_ lesson: Lesson) -> Bool {
    let type = (lesson.type ?? "").lowercased(), title = lesson.title.trimmingCharacters(in:.whitespaces).lowercased()
    return ["внеучеб","внеурочн","мероприят"].contains(where:type.contains) || ["мероприятие","внеурочное мероприятие","лекция по теме","экскурсия","фестиваль","встреча с ","встречи с ","тьюторский час"].contains(where:title.hasPrefix)
}

func timeMinutes(_ value: String?) -> Int { let parts = (value ?? "").split(separator: ":"); return parts.count >= 2 ? (Int(parts[0]) ?? 0) * 60 + (Int(parts[1].prefix(2)) ?? 0) : 0 }
func isoDate(_ lesson: Lesson) -> String { guard let date = lesson.begin else { return "" }; let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier:"Europe/Moscow"); return f.string(from:date) }

func isPaperTheme(_ theme: String) -> Bool { ["paper","mint","lavender","midnight","espresso"].contains(theme) }
func paperBackground(_ theme: String) -> Color { Color(hex:["paper":UInt32(0xF4F5F8),"mint":0xF1F8F5,"lavender":0xF6F4FB,"midnight":0xEEF1F8,"espresso":0xF7F3EF][theme] ?? 0xF4F5F8) }
