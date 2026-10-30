import SwiftUI
import UserNotifications
import EventKit
import UniformTypeIdentifiers

struct TargetChoice: Identifiable { let id: String; let title: String }
actor TargetDirectory {
    func load(mode: String) async throws -> [TargetChoice] {
        let path = mode == "teacher" ? "teacher" : (mode == "classroom" ? "classroom" : "")
        let url = URL(string: "https://schedule.siriusuniversity.ru/" + path)!
        let (data,response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let html = String(decoding: data, as: UTF8.self)
        let api = ScheduleAPI()
        if mode == "group" {
            let regex = try NSRegularExpression(pattern: #"data-group\s*=\s*["']([^"']+)["']"#)
            let values = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { Range($0.range(at: 1), in: html).map { String(html[$0]) } }
            return Array(Set(values)).sorted().map { TargetChoice(id: $0, title: $0) }
        }
        var raw = try await api.capture(#"wire:initial-data="([^"]+)""#, html)
        for (a,b) in [("&quot;", "\""),("&#039;", "'"),("&amp;", "&")] { raw = raw.replacingOccurrences(of: a, with: b) }
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String:Any]
        let memo = json?["serverMemo"] as? [String:Any]
        let state = memo?["data"] as? [String:Any] ?? [:]
        let value = state[mode == "teacher" ? "teachersList" : "classroomsList"]
        let values = (value as? [String:Any]).map { Array($0.values) } ?? (value as? [Any] ?? [])
        return values.compactMap { item in
            if mode == "classroom", let room = item as? String { return TargetChoice(id: "classroom:" + room, title: cleanRoom(room)) }
            guard let teacher = item as? [String:Any], let id = teacher["id"] as? String else { return nil }
            let name = teacher["fio"] as? String ?? ["last_name","first_name","middle_name"].compactMap { teacher[$0] as? String }.joined(separator: " ")
            return TargetChoice(id: "teacher:" + id, title: name)
        }.sorted { $0.title < $1.title }
    }
}
struct TargetSearchView: View {
    @AppStorage("group") private var group = ""
    @AppStorage("targetLabel") private var label = ""
    @State private var mode = "group"
    @State private var query = ""
    @State private var values: [TargetChoice] = []
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Picker("Расписание", selection: $mode) { Text("Группа").tag("group"); Text("Преподаватель").tag("teacher"); Text("Аудитория").tag("classroom") }.pickerStyle(.segmented)
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            ForEach(values.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { choice in
                Button(choice.title) { group = choice.id; label = choice.title; dismiss() }
            }
        }.searchable(text: $query, prompt: "Название или фамилия").navigationTitle("Поиск")
        .task(id: mode) { values = []; message = "Загрузка…"; do { values = try await TargetDirectory().load(mode: mode); message = values.isEmpty ? "Сайт не вернул список. Ключ можно ввести вручную в настройках расписания." : "" } catch { message = error.localizedDescription } }
    }
}
struct AnalyticsView: View {
    @AppStorage("group") private var group = ""
    var lessons: [Lesson] {
        let values = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("week-" + group + "-") }.values
        var seen = Set<String>()
        return values.compactMap { $0 as? Data }.flatMap { (try? JSONDecoder().decode([Lesson].self, from: $0)) ?? [] }.filter { seen.insert($0.id).inserted }
    }
    var body: some View {
        let items = lessons
        List {
            Section("Сохранённое расписание") { Text("Занятий: \(items.count)"); Text("Часов: \(items.reduce(0.0) { $0 + max(0, ($1.finish?.timeIntervalSince($1.begin ?? Date()) ?? 0) / 3600) }, specifier: "%.1f")") }
            Section("Нагрузка по предметам") { ForEach(Dictionary(grouping: items, by: \.title).keys.sorted(), id: \.self) { title in HStack { Text(title); Spacer(); Text("\(items.filter { $0.title == title }.count)") } } }
            Section("Аудитории") { ForEach(Array(Set(items.map(\.room).filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0) } }
            Section("Окна между занятиями") {
                ForEach(Dictionary(grouping: items, by: \.date).keys.sorted(), id: \.self) { day in
                    let sorted = items.filter { $0.date == day }.sorted { $0.start < $1.start }
                    ForEach(Array(sorted.dropFirst().enumerated()), id: \.offset) { index, next in
                        if let end = sorted[index].finish, let start = next.begin, start.timeIntervalSince(end) >= 1800 { Text("\(day): \(sorted[index].end) – \(next.start)") }
                    }
                }
            }
        }.navigationTitle("Аналитика")
    }
}
enum LessonAlertService {
    static func update(_ lessons: [Lesson]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("lesson-") }.map(\.identifier))
        guard UserDefaults.standard.bool(forKey: "lessonAlerts") else { return }
        let minutes = UserDefaults.standard.object(forKey: "alertMinutes") as? Int ?? 10
        for lesson in lessons.sorted(by: { ($0.begin ?? .distantPast) < ($1.begin ?? .distantPast) }).prefix(48) {
            guard let start = lesson.begin else { continue }
            let fire = start.addingTimeInterval(-Double(minutes)*60)
            guard fire > Date() else { continue }
            let content = UNMutableNotificationContent(); content.title = lesson.title; content.body = lesson.start + " · " + lesson.room; content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "lesson-" + lesson.id, content: content, trigger: trigger))
        }
    }
}
struct LessonAlertsView: View {
    @AppStorage("lessonAlerts") private var enabled = false
    @AppStorage("alertMinutes") private var minutes = 10
    @State private var message = ""
    var body: some View { Form {
        Toggle("Напоминать о занятиях", isOn: $enabled).onChange(of: enabled) { _, value in Task {
            if value { do { enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound]); message = enabled ? "Обновите расписание для планирования напоминаний." : "Разрешите уведомления в настройках iOS." } catch { message = error.localizedDescription } }
            else { await LessonAlertService.update([]) }
        } }
        Picker("За сколько минут", selection: $minutes) { ForEach([0,5,10,15,30,60], id: \.self) { Text("\($0) мин").tag($0) } }
        Text(message)
    }.navigationTitle("Напоминания") }
}
struct CalendarFile: FileDocument {
    static var readableContentTypes: [UTType] { [.calendarEvent] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
struct CalendarExportView: View {
    @AppStorage("group") private var group = ""
    @State private var exporting = false
    @State private var document = CalendarFile(text: "")
    @State private var message = ""
    func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ";", with: "\\;") }
    var body: some View { Form {
        Text("Экспорт сохранённых занятий в файл календаря для Apple Calendar и Outlook.")
        Button("Экспортировать .ics") {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            var lines = ["BEGIN:VCALENDAR","VERSION:2.0","PRODID:-//Lecturial//iOS//RU"]
            var seen = Set<String>()
            for (key,value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("week-" + group + "-") {
                guard let data = value as? Data, let lessons = try? JSONDecoder().decode([Lesson].self, from: data) else { continue }
                for lesson in lessons where seen.insert(lesson.id).inserted {
                    guard let start = lesson.begin, let end = lesson.finish else { continue }
                    let uid = Data(lesson.id.utf8).base64EncodedString()
                    lines += ["BEGIN:VEVENT","UID:" + uid + "@lecturial","DTSTAMP:" + formatter.string(from: Date()),"DTSTART:" + formatter.string(from: start),"DTEND:" + formatter.string(from: end),"SUMMARY:" + escape(lesson.title),"LOCATION:" + escape(lesson.room),"END:VEVENT"]
                }
            }
            lines.append("END:VCALENDAR"); document = CalendarFile(text: lines.joined(separator: "\r\n")); exporting = true
        }
        Text(message)
    }.navigationTitle("Календарь").fileExporter(isPresented: $exporting, document: document, contentType: .calendarEvent, defaultFilename: "Lecturial.ics") { result in if case .failure(let error) = result { message = error.localizedDescription } } }
}
