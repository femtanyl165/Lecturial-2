import SwiftUI
import WidgetKit
func isForeignLanguage(_ title: String) -> Bool { let name = title.lowercased().replacingOccurrences(of:"ё",with:"е"); return ["иностранн","английск","немецк","французск","иняз"].contains(where:name.contains) }
func selectedLanguageTeacher(_ group: String) -> String { UserDefaults.standard.string(forKey:"languageTeacher-" + group) ?? "" }
func matchesLanguageTeacher(_ lesson: Lesson,group: String) -> Bool {
    let teacher = selectedLanguageTeacher(group).trimmingCharacters(in:.whitespacesAndNewlines)
    return group.hasPrefix("teacher:") || group.hasPrefix("classroom:") || teacher.isEmpty || !isForeignLanguage(lesson.title) || lesson.teacher.trimmingCharacters(in:.whitespaces).isEmpty || lesson.teacher.split(separator:",").contains { $0.trimmingCharacters(in:.whitespacesAndNewlines).localizedCaseInsensitiveCompare(teacher) == .orderedSame }
}
struct LanguageTeacherPicker: View {
    @AppStorage("group") private var group = ""
    @State private var teachers: [String] = []
    @State private var selected = ""
    @State private var message = ""
    @State private var loading = false
    @State private var manual = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Преподаватель иностранного языка").font(.headline)
            Text("Выберите своего преподавателя, чтобы пары других подгрупп не показывались.").font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView("Загружаем преподавателей…") }
            Picker("Преподаватель",selection:$selected) { Text("Все преподаватели").tag(""); ForEach(teachers,id:\.self) { Text($0).tag($0) } }
                .onChange(of:selected) { _,value in UserDefaults.standard.set(value,forKey:"languageTeacher-" + group); UserDefaults.standard.set(UserDefaults.standard.integer(forKey:"languageTeacherRevision") + 1,forKey:"languageTeacherRevision"); Task { await SystemFeatures.update(UpdateData.lessons(),group:group); await LessonAlertService.update(UpdateData.lessons().filter { matchesLanguageTeacher($0,group:group) }) } }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            if teachers.isEmpty && !loading { TextField("ФИО преподавателя как в расписании",text:$manual); Button("Сохранить преподавателя") { let value = manual.trimmingCharacters(in:.whitespacesAndNewlines); if !value.isEmpty { teachers = [value]; selected = value } } }
        }.task(id:group) {
            guard !group.isEmpty,!group.hasPrefix("teacher:"),!group.hasPrefix("classroom:") else { return }
            loading = true; defer { loading = false }
            selected = selectedLanguageTeacher(group)
            var lessons = UpdateData.lessons()
            do { let week = Calendar(identifier:.iso8601).dateInterval(of:.weekOfYear,for:Date())!.start; lessons += try await ScheduleAPI().fetch(group:group,week:week); if !lessons.contains(where:{ isForeignLanguage($0.title) }) { lessons += try await ScheduleAPI().fetch(group:group,week:week.addingTimeInterval(7*86400)) } }
            catch { message = "Не удалось загрузить преподавателей. Можно указать ФИО вручную или выбрать позже." }
            teachers = Array(Set(lessons.filter { isForeignLanguage($0.title) }.flatMap { $0.teacher.split(separator:",").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) } }.filter { !$0.isEmpty })).sorted()
            if !selected.isEmpty && !teachers.contains(selected) { teachers.append(selected) }
            if teachers.isEmpty && message.isEmpty { message = "В загруженном расписании пока нет пар иностранного языка." }
        }
    }
}
