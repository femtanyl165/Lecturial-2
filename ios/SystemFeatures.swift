import SwiftUI
import WidgetKit
import ActivityKit

struct WidgetLesson: Codable { var title: String; var room: String; var start: Date; var end: Date }
@MainActor enum SystemFeatures {
    static func update(_ lessons: [Lesson], group: String) async {
        var seen = Set<String>()
        let cached = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("week-" + group + "-") }.values.compactMap { $0 as? Data }.flatMap { (try? JSONDecoder().decode([Lesson].self, from: $0)) ?? [] }
        let allLessons = (lessons + cached).filter { seen.insert($0.id).inserted && matchesLanguageTeacher($0,group:group) }.sorted { ($0.begin ?? .distantPast) < ($1.begin ?? .distantPast) }
        let items = allLessons.compactMap { lesson -> WidgetLesson? in guard let start = lesson.begin, let end = lesson.finish else { return nil }; return WidgetLesson(title: lesson.title, room: cleanRoom(lesson.room), start: start, end: end) }
        do { try WidgetStore.write(JSONEncoder().encode(items)); UserDefaults.standard.set("Виджету передано занятий: \(items.count)",forKey:"widgetStatus") }
        catch { UserDefaults.standard.set(error.localizedDescription,forKey:"widgetStatus") }
        WidgetCenter.shared.reloadAllTimelines()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard UserDefaults.standard.bool(forKey: "liveActivities"), let item = items.first(where: { $0.start <= Date() && $0.end > Date() }) else {
            for activity in Activity<LessonActivity>.activities { await activity.end(nil, dismissalPolicy: .immediate) }; return
        }
        let state = LessonActivity.ContentState(title: item.title, room: item.room, start: item.start, end: item.end)
        let content = ActivityContent(state: state, staleDate: item.end)
        if let activity = Activity<LessonActivity>.activities.first { await activity.update(content) }
        else { _ = try? Activity.request(attributes: LessonActivity(group: group), content: content) }
    }
}
