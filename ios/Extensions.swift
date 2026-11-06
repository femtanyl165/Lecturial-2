import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

struct Snapshot: Codable { var title: String; var room: String; var start: Date; var end: Date }
struct WidgetPlan: Codable { var title: String; var due: Date; var completed: Bool }
struct Entry: TimelineEntry { var date: Date; var lessons: [Snapshot] }
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), lessons: []) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(read()) }
    func read() -> Entry {
        let data = WidgetStore.read() ?? WidgetStore.defaults?.data(forKey: "widgetLessons")
        return Entry(date: Date(), lessons: data.flatMap { try? JSONDecoder().decode([Snapshot].self, from: $0) } ?? [])
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = read()
        let boundaries = entry.lessons.flatMap { [$0.start,$0.end] }.filter { $0 > Date() && $0 < Date().addingTimeInterval(86400) }
        completion(Timeline(entries: [entry] + Array(Set(boundaries)).sorted().map { Entry(date: $0, lessons: entry.lessons) }, policy: .after(Date().addingTimeInterval(1800))))
    }
}
struct WidgetPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Следующие занятия"
    func perform() async throws -> some IntentResult {
        let store = WidgetStore.defaults
        store?.set((store?.integer(forKey: "widgetPage") ?? 0) + 1, forKey: "widgetPage")
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
struct DayWidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let calendar = Calendar(identifier: .gregorian)
        let items = entry.lessons.filter { calendar.isDate($0.start, inSameDayAs: entry.date) }.sorted { $0.start < $1.start }
        let capacity = family == .systemLarge ? 6 : (family == .systemMedium ? 3 : 2)
        let pages = max(1, Int(ceil(Double(items.count) / Double(capacity))))
        let page = (WidgetStore.defaults?.integer(forKey: "widgetPage") ?? 0) % pages
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(entry.date, format: .dateTime.weekday().day().month()).font(.caption.bold()); Spacer(); Text("\(items.count) пар").font(.caption2) }
            if items.isEmpty { Text(WidgetStore.location == nil ? "Нет доступа к App Group. Проверьте подпись расширения." : (WidgetStore.read() == nil ? "Откройте приложение и обновите расписание." : "На сегодня занятий нет.")).font(.caption) }
            ForEach(Array(items.dropFirst(page * capacity).prefix(capacity).enumerated()), id: \.offset) { _, lesson in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(lesson.start <= entry.date && entry.date < lesson.end ? Color.green : Color.blue).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lesson.title).font(.caption.bold()).lineLimit(2)
                        HStack(spacing: 2) { Text(lesson.start, style: .time); Text("–"); Text(lesson.end, style: .time); Text(cleanRoom(lesson.room)).lineLimit(1) }.font(.system(size: 10))
                    }
                }.frame(maxHeight: 58)
            }
            Spacer(minLength: 0)
            if pages > 1 { Button(intent: WidgetPageIntent()) { HStack { Text("\(page + 1)/\(pages)"); Spacer(); Image(systemName: "chevron.right") } }.font(.caption2).buttonStyle(.plain) }
        }.containerBackground(for: .widget) { Color(white: 0.18) }.foregroundStyle(.white)
    }
}
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LecturialToday", provider: Provider()) { entry in DayWidgetView(entry: entry) }
        .configurationDisplayName("Lecturial · День").description("Все занятия на сегодня, включая прошедшие. Кнопка переключает страницы.").supportedFamilies([.systemSmall,.systemMedium,.systemLarge])
    }
}
struct LiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LessonActivity.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                Text(context.state.title).font(.headline).lineLimit(2)
                HStack {
                    Label(cleanRoom(context.state.room), systemImage: "mappin.and.ellipse").font(.subheadline).lineLimit(1)
                    Spacer(minLength: 12)
                    countdown(context.state).font(.subheadline.monospacedDigit()).frame(width: 66, alignment: .trailing)
                }
                ProgressView(timerInterval: context.state.start...context.state.end, countsDown: false).tint(.init(red: 0.72, green: 0.78, blue: 1))
            }.padding(16).activityBackgroundTint(.black).activitySystemActionForegroundColor(.white).foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "graduationcap.fill").font(.system(size: 20)).frame(width: 28, height: 28)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context.state).font(.system(.subheadline, design: .rounded).monospacedDigit()).frame(width: 64, height: 28, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.state.title).font(.system(.headline, design: .rounded)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Label(cleanRoom(context.state.room), systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        ProgressView(timerInterval: context.state.start...context.state.end, countsDown: false).tint(.init(red: 0.72, green: 0.78, blue: 1))
                    }.padding(.top, 4).padding(.bottom, 8).padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "graduationcap.fill").font(.system(size: 14)).frame(width: 22, height: 22)
            } compactTrailing: {
                countdown(context.state).font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit()).frame(width: 52, alignment: .trailing)
            } minimal: {
                Image(systemName: "graduationcap.fill").font(.system(size: 14))
            }
        }
    }
    func countdown(_ state: LessonActivity.ContentState) -> some View {
        Text(timerInterval: state.start...max(state.start, state.end), countsDown: true, showsHours: false).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
    }
}
@main struct LecturialWidgets: WidgetBundle { var body: some Widget { TodayWidget(); LiveWidget() } }
