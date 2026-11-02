import SwiftUI
import WebKit
import EventKit
import UserNotifications

struct JournalMark: Codable, Identifiable {
    var id: String; var discipline: String; var date: String; var time: String?; var type: String; var grade: Double?; var absent: Bool?; var topic: String?; var homework: String?
}
struct AssessmentSubject: Codable, Identifiable {
    var id: String { semester + name }; var semester: String; var name: String; var controls: [String]; var results: [String]; var hours: Double?; var credits: Double?; var passed: Bool?
    var kind: String { controls.contains(where: { $0.lowercased().contains("дифф") }) ? "Дифф. зачёт" : controls.contains(where: { $0.lowercased().contains("экзам") }) ? "Экзамен" : controls.contains(where: { $0.lowercased().contains("зач") }) ? "Зачёт" : "Контроль" }
}
struct AccountNotice: Codable, Identifiable { var id: String; var title: String; var text: String; var time: String }
struct AccountNews: Codable, Identifiable { var id: String; var title: String; var date: String }
struct AccountSnapshot: Codable { var marks: [JournalMark] = []; var subjects: [AssessmentSubject] = []; var news: [String] = []; var notifications: [String] = []; var loaded = Date(); var noticeItems: [AccountNotice]?; var newsItems: [AccountNews]?; var unread: Int? }
func normalizedSubject(_ value: String) -> String { value.lowercased().replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
func sameSubject(_ a: String, _ b: String) -> Bool { let a = normalizedSubject(a), b = normalizedSubject(b); return !a.isEmpty && !b.isEmpty && (a.hasPrefix(b) || b.hasPrefix(a)) }
@MainActor final class AccountStore: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = AccountStore()
    @Published var snapshot = AccountSnapshot()
    @Published var message = ""
    @Published var busy = false
    let browser = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private var cache: URL { URL.applicationSupportDirectory.appendingPathComponent("lecturial-account.json") }
    override init() {
        super.init(); browser.navigationDelegate = self
        if let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode(AccountSnapshot.self, from: data) { snapshot = saved }
    }
    func open() { browser.load(URLRequest(url: URL(string:"https://lks.siriusuniversity.ru/login")!)) }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let script = #"""
            (async()=>{
              async function page(path){const r=await fetch(path,{credentials:'include'});if(!r.ok)throw Error('HTTP '+r.status);if(new URL(r.url).pathname.startsWith('/login'))throw Error('Сессия истекла — войдите заново');return new DOMParser().parseFromString(await r.text(),'text/html');}
              function component(doc,name){for(const el of doc.querySelectorAll('[wire\\:initial-data]')){const o=JSON.parse(el.getAttribute('wire:initial-data'));if(o.fingerprint.name===name)return o.serverMemo.data;}return {};}
              const j=component(await page('/journal/list'),'journal-list');
              const t=component(await page('/student/trajectory'),'trajectory');
              const d=await page('/dashboard');
              const tidy=x=>(x||'').replace(/\s+/g,' ').trim();
              const components=Array.from(d.querySelectorAll('[wire\\:initial-data]'));
              const menu=components.find(el=>{try{return JSON.parse(el.getAttribute('wire:initial-data')).fingerprint.name==='user-notifications-menu'}catch{return false}});
              const noticeItems=[], seenNotices=new Set();
              if(menu)for(const el of menu.querySelectorAll('[wire\\:click^="openNotification"]')){
                const m=(el.getAttribute('wire:click')||'').match(/openNotification\('([^']+)'\)/);if(!m||seenNotices.has(m[1]))continue;seenNotices.add(m[1]);
                const parts=Array.from(el.querySelectorAll('div')).filter(x=>x.children.length===0).map(x=>tidy(x.textContent)).filter(Boolean);
                noticeItems.push({id:m[1],title:parts[0]||tidy(el.textContent),text:parts[1]||'',time:parts[2]||''});
              }
              const newsItems=[],seenNews=new Set();
              for(const el of d.querySelectorAll('a[href*="/news/show/"]')){
                if(menu&&menu.contains(el))continue;
                if(el.closest('[wire\\:click^="openNotification"]'))continue;
                const m=el.getAttribute('href').match(/\/news\/show\/(\d+)/);if(!m||seenNews.has(m[1]))continue;seenNews.add(m[1]);
                const text=tidy(el.textContent),dt=text.match(/\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2}(?::\d{2})?)?/);
                const date=dt?dt[0]:'';const title=tidy(text.replace(date,'').replace('Подробнее',''));
                if(title)newsItems.push({id:m[1],title,date});
              }
              const count=menu?tidy(menu.textContent).match(/^\s*(\d+)/):null;
              return JSON.stringify({journal:j,trajectory:t,news:newsItems.map(x=>x.title),notifications:noticeItems.map(x=>x.title),noticeItems,newsItems,unread:count?Number(count[1]):0});
            })()
            """#
            let result = try await browser.callAsyncJavaScript("return await " + script, arguments: [:], in: nil, contentWorld: .page)
            guard let text = result as? String, let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String:Any] else { throw URLError(.cannotParseResponse) }
            var marks: [String:JournalMark] = [:]
            let journal = root["journal"] as? [String:Any] ?? [:]
            for year in (journal["grades"] as? [String:Any] ?? [:]).values {
                for (dateKey,day) in year as? [String:Any] ?? [:] {
                    let disciplines = (day as? [String:Any])?["disciplines"] as? [String:Any] ?? [:]
                    for raw in disciplines.values {
                        let discipline = raw as? [String:Any] ?? [:]
                        for value in (discipline["grades"] as? [String:Any] ?? [:]).values {
                            guard let mark = value as? [String:Any], let id = mark["mark_id"].map({ String(describing:$0) }) else { continue }
                            func number(_ key: String) -> Double? { if let n = mark[key] as? NSNumber { return n.doubleValue }; return (mark[key] as? String).flatMap(Double.init) }
                            marks[id] = JournalMark(id:id,discipline:discipline["discipline"] as? String ?? "",date:mark["start_date"] as? String ?? dateKey,time:mark["start_time"] as? String,type:mark["action_type_name"] as? String ?? "",grade:number("grade_as_long"),absent:number("absent").map { $0 != 0 },topic:mark["subject"] as? String,homework:mark["homework"] as? String)
                        }
                    }
                }
            }
            var subjects: [AssessmentSubject] = []
            let trajectory = root["trajectory"] as? [String:Any] ?? [:]
            for (key,value) in trajectory["semesters"] as? [String:Any] ?? [:] {
                let semester = value as? [String:Any] ?? [:]
                for (name,value) in semester["disciplines"] as? [String:Any] ?? [:] {
                    let subject = value as? [String:Any] ?? [:]
                    let elements = subject["elements"] as? [String:Any] ?? [:]
                    let controls = ((elements["regel_part"] as? [String:Any])?["control_actions"] as? [[String:Any]] ?? []).compactMap { ($0["control_action"] as? [String:Any])?["title"] as? String }
                    let actions = (subject["actionType"] as? [String:[String:Any]] ?? [:]).values.map { $0["passed"] as? Bool }
                    let passed: Bool? = actions.isEmpty || actions.contains(where: { $0 == nil }) ? nil : !actions.contains(false)
                    subjects.append(AssessmentSubject(semester:semester["yearTitle"] as? String ?? key,name:name,controls:controls,results:(subject["marks"] as? [Any] ?? []).compactMap { value in if let s = value as? String { return s }; if let n = value as? NSNumber { return n.stringValue }; let v = value as? [String:Any] ?? [:]; return ["title","mark","value","short_title","grade"].compactMap { v[$0].map { String(describing:$0) } }.first },hours:(subject["size"] as? NSNumber)?.doubleValue,credits:(subject["labor"] as? NSNumber)?.doubleValue,passed:passed))
                }
            }
            let old = Dictionary(uniqueKeysWithValues: snapshot.marks.map { ($0.id,$0) })
            let changed = marks.values.filter { old[$0.id] == nil || old[$0.id]?.grade != $0.grade }
            if !snapshot.marks.isEmpty && UserDefaults.standard.bool(forKey:"accountAlerts") {
                for mark in changed.prefix(10) { let content = UNMutableNotificationContent(); content.title = mark.discipline; content.body = mark.grade.map { "Новая оценка: \($0)" } ?? "Обновление журнала"; try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"mark-" + mark.id, content:content, trigger:nil)) }
            }
            snapshot = AccountSnapshot(marks:Array(marks.values).sorted { $0.date > $1.date },subjects:subjects.sorted { $0.id < $1.id },news:root["news"] as? [String] ?? [],notifications:root["notifications"] as? [String] ?? [],loaded:Date(),noticeItems:try JSONDecoder().decode([AccountNotice].self,from:JSONSerialization.data(withJSONObject:root["noticeItems"] ?? [])),newsItems:try JSONDecoder().decode([AccountNews].self,from:JSONSerialization.data(withJSONObject:root["newsItems"] ?? [])),unread:root["unread"] as? Int)
            try FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(snapshot).write(to:cache,options:[.atomic,.completeFileProtection])
            message = "Обновлено"
        } catch { message = error.localizedDescription }
    }
    func disconnect() async {
        let store = browser.configuration.websiteDataStore
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),for:records.filter { $0.displayName.contains("sirius") })
        snapshot = AccountSnapshot(); try? FileManager.default.removeItem(at:cache); message = "Личный кабинет отключён"
    }
}
struct AccountBrowser: UIViewRepresentable { let web: WKWebView; func makeUIView(context: Context) -> WKWebView { web }; func updateUIView(_ uiView: WKWebView,context:Context) {} }
struct PlannerBlock: Identifiable { var id: String { title + String(start.timeIntervalSince1970) }; var start: Date; var end: Date; var title: String; var kind: String; var key: String? }
@MainActor enum UpdateData {
    static func lessons() -> [Lesson] {
        let group = UserDefaults.standard.string(forKey:"group") ?? ""
        var ids = Set<String>()
        return UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("week-" + group + "-") }.values.compactMap { $0 as? Data }.flatMap { (try? JSONDecoder().decode([Lesson].self,from:$0)) ?? [] }.filter { ids.insert($0.id).inserted }
    }
    static func plans() -> [StudyTask] { UserDefaults.standard.data(forKey:"plans").flatMap { try? JSONDecoder().decode([StudyTask].self,from:$0) } ?? [] }
}
struct DayPlannerView: View {
    @State private var date = Date()
    @AppStorage("plannerStart") private var startHour = 8
    @AppStorage("plannerEnd") private var endHour = 22
    @AppStorage("plannerBlock") private var block = 45
    @AppStorage("plannerBreak") private var rest = 10
    @AppStorage("plannerBudget") private var budget = 240
    @State private var done = Set<String>()
    var key: String { "plannerDone-" + Calendar.current.startOfDay(for:date).timeIntervalSince1970.description }
    var blocks: [PlannerBlock] {
        let calendar = Calendar.current
        let beginning = calendar.startOfDay(for:date)
        var busy = UpdateData.lessons().filter { $0.begin.map { calendar.isDate($0,inSameDayAs:date) } ?? false }.compactMap { lesson -> PlannerBlock? in guard let start = lesson.begin,let end = lesson.finish else { return nil }; return PlannerBlock(start:start,end:end,title:lesson.title,kind:"Пара") }.sorted { $0.start < $1.start }
        let plans = UpdateData.plans().filter { !$0.completed }
        busy += plans.filter { $0.kind == "event" && calendar.isDate($0.due,inSameDayAs:date) }.map { PlannerBlock(start:$0.due,end:$0.due.addingTimeInterval(1800),title:$0.title,kind:"Событие") }
        if let last = busy.filter({ $0.kind == "Пара" }).max(by:{ $0.end < $1.end }), !busy.contains(where:{ $0.start >= last.end && $0.start < last.end.addingTimeInterval(1800) }) { busy.append(PlannerBlock(start:last.end,end:last.end.addingTimeInterval(1800),title:"Отдых после пар",kind:"Отдых")) }
        var tasks: [(String,String,Int,Double)] = []
        for plan in plans where plan.kind != "goal" && plan.kind != "event" && plan.due < beginning.addingTimeInterval(8*86400) { let days = plan.due.timeIntervalSince(beginning)/86400; tasks.append(("plan-"+plan.id.uuidString,plan.title,plan.kind == "deadline" ? 60 : 30, days < 0 ? 5 : 2.5 + 3/(days+1))) }
        for mark in AccountStore.shared.snapshot.marks where !(mark.homework ?? "").isEmpty { tasks.append(("hw-"+mark.id,"ДЗ: " + mark.discipline,block,4)) }
        var subjects = Set<String>()
        for lesson in UpdateData.lessons().sorted(by:{ ($0.begin ?? .distantPast) < ($1.begin ?? .distantPast) }) where (lesson.begin ?? .distantPast) > beginning && (lesson.begin ?? .distantFuture) < beginning.addingTimeInterval(14*86400) {
            let name = normalizedSubject(lesson.title)
            if subjects.insert(name).inserted && !name.contains("физкульт") { tasks.append(("review-"+name,"Подготовка: " + lesson.title,30,1.5)) }
        }
        var queue = tasks.filter { !done.contains($0.0) }.sorted { $0.3 > $1.3 }
        var result = busy
        var at = beginning.addingTimeInterval(Double(startHour)*3600)
        if calendar.isDateInToday(date) { at = max(at,Date()) }
        let end = beginning.addingTimeInterval(Double(endHour)*3600)
        var remaining = budget
        for boundary in busy.sorted(by:{ $0.start < $1.start }) + [PlannerBlock(start:end,end:end,title:"",kind:"")] {
            let until = min(end,boundary.start)
            while !queue.isEmpty && remaining >= 15 && until.timeIntervalSince(at) >= 900 {
                var task = queue.removeFirst()
                let minutes = min(block,remaining,task.2,Int(until.timeIntervalSince(at)/60))
                result.append(PlannerBlock(start:at,end:at.addingTimeInterval(Double(minutes)*60),title:task.1,kind:"Учёба",key:task.0))
                at = at.addingTimeInterval(Double(minutes)*60); remaining -= minutes; task.2 -= minutes
                if task.2 >= 15 { queue.insert(task,at:0) }
                if !queue.isEmpty && until.timeIntervalSince(at) >= Double(rest+15)*60 { result.append(PlannerBlock(start:at,end:at.addingTimeInterval(Double(rest)*60),title:"Перерыв",kind:"Отдых")); at = at.addingTimeInterval(Double(rest)*60) }
            }
            if until.timeIntervalSince(at) >= 600 { result.append(PlannerBlock(start:at,end:until,title:"Свободное время",kind:"Свободно")) }
            at = max(at,boundary.end)
            if at >= end { break }
        }
        return result.sorted { $0.start < $1.start }
    }
    var body: some View { List {
        DatePicker("День",selection:$date,displayedComponents:.date)
        DisclosureGroup("Настройки дня") { Stepper("Начало: \(startHour):00",value:$startHour,in:0...20); Stepper("Конец: \(endHour):00",value:$endHour,in:(startHour+1)...24); Stepper("Блок: \(block) мин",value:$block,in:15...90,step:5); Stepper("Перерыв: \(rest) мин",value:$rest,in:5...30,step:5); Stepper("Учёба за день: \(budget) мин",value:$budget,in:30...480,step:30) }
        ForEach(blocks) { item in HStack { VStack(alignment:.leading,spacing:5) { HStack { Text(item.start,style:.time); Text("–"); Text(item.end,style:.time) }.font(.caption.monospaced()); Text(item.title).font(.headline); Text(item.kind).font(.caption).foregroundStyle(.secondary) }; Spacer(); if let task = item.key { Button { done.insert(task); UserDefaults.standard.set(Array(done),forKey:key) } label: { Image(systemName:"checkmark.circle") } } } }
    }.navigationTitle("План дня").task(id:key) { done = Set(UserDefaults.standard.stringArray(forKey:key) ?? []) } }
}
@MainActor final class PhoneCalendar: ObservableObject {
    static let shared = PhoneCalendar()
    let store = EKEventStore()
    @Published var calendars: [EKCalendar] = []
    @Published var message = ""
    @Published var busy = false
    func connect() async { do { guard try await store.requestFullAccessToEvents() else { message = "Нет доступа к календарю"; return }; calendars = store.calendars(for:.event).filter(\.allowsContentModifications) } catch { message = error.localizedDescription } }
    func sync() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        guard let id = UserDefaults.standard.string(forKey:"phoneCalendar"),let calendar = store.calendar(withIdentifier:id),EKEventStore.authorizationStatus(for:.event) == .fullAccess else { return }
        do {
            var mapping = UserDefaults.standard.dictionary(forKey:"phoneCalendarMap") as? [String:String] ?? [:]
            var entries: [(String,String,Date,Date,String)] = []
            if UserDefaults.standard.object(forKey:"phoneCalendarLessons") as? Bool ?? true { for lesson in UpdateData.lessons() { if let start = lesson.begin,let end = lesson.finish,start > Date().addingTimeInterval(-86400) { entries.append(("lesson-"+lesson.id,lesson.title,start,end,cleanRoom(lesson.room))) } } }
            if UserDefaults.standard.object(forKey:"phoneCalendarPlans") as? Bool ?? true { for plan in UpdateData.plans() where !plan.completed { entries.append(("plan-"+plan.id.uuidString,plan.title,plan.due,plan.due.addingTimeInterval(1800),plan.note ?? "")) } }
            let predicate = store.predicateForEvents(withStart: Calendar.current.startOfDay(for:Date()), end: Date().addingTimeInterval(90*86400), calendars:[calendar])
            let owned = store.events(matching:predicate).filter { ($0.notes ?? "").hasPrefix("Lecturial · ") }
            var marked: [String:EKEvent] = [:]
            for event in owned { let key = String((event.notes ?? "").dropFirst("Lecturial · ".count)); if marked[key] == nil { marked[key] = event } else { try store.remove(event,span:.thisEvent,commit:false) } }
            var keys = Set<String>()
            for (key,title,start,end,location) in entries {
                keys.insert(key)
                let event = mapping[key].flatMap { store.event(withIdentifier:$0) } ?? marked[key] ?? EKEvent(eventStore:store)
                event.calendar = calendar; event.title = title; event.startDate = start; event.endDate = end; event.location = location; event.notes = "Lecturial · " + key
                try store.save(event,span:.thisEvent,commit:true); mapping[key] = event.eventIdentifier; UserDefaults.standard.set(mapping,forKey:"phoneCalendarMap")
            }
            for (key,id) in mapping where !keys.contains(key) { if let event = store.event(withIdentifier:id),event.startDate >= Calendar.current.startOfDay(for:Date()) { try store.remove(event,span:.thisEvent,commit:false); mapping.removeValue(forKey:key) } }
            try store.commit(); UserDefaults.standard.set(mapping,forKey:"phoneCalendarMap"); message = "Синхронизировано: \(entries.count) событий"
        } catch { store.reset(); message = error.localizedDescription }
    }
}
struct PhoneCalendarView: View {
    @ObservedObject private var service = PhoneCalendar.shared
    @AppStorage("phoneCalendar") private var selected = ""
    @AppStorage("phoneCalendarLessons") private var lessons = true
    @AppStorage("phoneCalendarPlans") private var plans = true
    var body: some View { Form { Text("Выберите календарь iCloud, Google или другого аккаунта, добавленного в настройках iPhone."); Button("Разрешить доступ и загрузить календари") { Task { await service.connect() } }; Picker("Календарь",selection:$selected) { Text("Не выбран").tag(""); ForEach(service.calendars,id:\.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) } }; Toggle("Занятия",isOn:$lessons); Toggle("Планы",isOn:$plans); Button("Синхронизировать") { Task { await service.sync() } }.disabled(service.busy); Text(service.message) }.navigationTitle("Календари устройства") }
}
struct FirstSetupView: View {
    @AppStorage("setupFinished") private var finished = false
    @AppStorage("group") private var group = ""
    @AppStorage("scheduleLayout") private var layout = "feed"
    @State private var step = 0
    var body: some View { NavigationStack { VStack(alignment:.leading,spacing:24) {
        ProgressView(value:Double(step),total:5)
        Text(["Добро пожаловать","Ваше расписание","Личный кабинет","Уведомления","Вид расписания","Всё готово"][step]).font(.largeTitle.bold())
        if step == 0 { Image("LecturialAvatar").resizable().frame(width:100,height:100).clipShape(RoundedRectangle(cornerRadius:28)); Text("Расписание, оценки, планы и календари — в одном приложении") }
        if step == 1 { GroupAutocomplete(group:$group); NavigationLink("Поиск группы или преподавателя") { TargetSearchView() } }
        if step == 2 { NavigationLink("Подключить личный кабинет") { ExpressiveStudyView() }; Text("Можно подключить позже во вкладке «Учёба»") }
        if step == 3 { Button("Разрешить уведомления") { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge]) } } }
        if step == 4 { LayoutChooser(layout:$layout); NavigationLink("Настроить оформление") { AppearanceView() } }
        if step == 5 { Text("Добавьте виджет на экран, подключите календарь и откройте план дня во вкладке «Планы».") }
        Spacer()
        Button(step == 5 ? "Открыть приложение" : "Далее") { if step == 5 { finished = true } else { step += 1 } }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        Button("Пропустить") { finished = true }
    }.padding(24) } }
}

struct LayoutChooser: View {
    @Binding var layout: String
    var body: some View { HStack(alignment:.top,spacing:12) {
        option("feed","Лентой","Все дни одним списком")
        option("days","По дням","Один день · свайп влево и вправо")
    } }
    func option(_ key: String,_ title: String,_ detail: String) -> some View {
        Button { layout = key } label: { VStack(alignment:.leading,spacing:12) {
            VStack(alignment:.leading,spacing:8) {
                if key == "days" { HStack { ForEach(0..<7,id:\.self) { i in Circle().fill(i == 2 ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width:12,height:12) } } }
                ForEach(0..<(key == "feed" ? 4 : 2),id:\.self) { index in
                    if index == 0 || (key == "feed" && index == 2) { Capsule().fill(Color.accentColor.opacity(0.65)).frame(width:60,height:6) }
                    HStack { Capsule().fill(Color.accentColor).frame(width:3,height:22); VStack(alignment:.leading,spacing:5) { Capsule().fill(.secondary.opacity(0.4)).frame(height:5); Capsule().fill(.secondary.opacity(0.2)).frame(width:55,height:5) } }.padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
                }
                Spacer(minLength:0)
            }.frame(height:160).padding(10).background(.background,in:RoundedRectangle(cornerRadius:16))
            Label(title,systemImage:layout == key ? "largecircle.fill.circle" : "circle").font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).frame(height:36,alignment:.top)
        }.padding(12).frame(maxWidth:.infinity).background(layout == key ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.09),in:RoundedRectangle(cornerRadius:24)).overlay { RoundedRectangle(cornerRadius:24).strokeBorder(layout == key ? Color.accentColor : Color.secondary.opacity(0.2),lineWidth:layout == key ? 2 : 1) } }.buttonStyle(.plain).accessibilityAddTraits(layout == key ? .isSelected : [])
    }
}
struct ExpressiveStudyView: View {
    @ObservedObject private var account = AccountStore.shared
    @State private var login = false
    @State private var tab = "grades"
    @AppStorage("theme") private var theme = "sirius"
    @AppStorage("customAccent") private var custom = "B7C7FF"
    @AppStorage("accountAlerts") private var alerts = false
    var marks: [JournalMark] { account.snapshot.marks }
    var body: some View {
        NavigationStack { ScrollView { LazyVStack(alignment:.leading,spacing:18) {
            HStack { VStack(alignment:.leading,spacing:4) { Text("Учёба").font(.largeTitle.bold()); Text(marks.isEmpty ? "Личный кабинет студента" : "Обновлено " + account.snapshot.loaded.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { Task { await account.refresh() } } label: { Image(systemName:"arrow.clockwise").padding(12).background(.quaternary,in:Circle()) }.disabled(account.busy) }
            if account.busy { ProgressView() }
            if !account.message.isEmpty && account.message != "Обновлено" { Text(account.message).font(.caption).foregroundStyle(.secondary) }
            if marks.isEmpty && account.snapshot.subjects.isEmpty {
                VStack(alignment:.leading,spacing:16) { Image(systemName:"graduationcap.fill").font(.largeTitle); Text("Ваша учёба в одном месте").font(.title2.bold()); Text("Оценки, посещаемость, домашние задания и сессия из личного кабинета Сириуса.").foregroundStyle(.secondary); Button("Войти в личный кабинет") { account.open(); login = true }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule) }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:28))
            } else {
                ScrollView(.horizontal,showsIndicators:false) { HStack(spacing:6) { tabButton("grades","Оценки"); tabButton("session","Сессия"); tabButton("alerts","Уведомления"); tabButton("news","Новости") } }.padding(.vertical,6)
                if tab == "grades" { gradesContent }
                if tab == "session" { ForEach(account.snapshot.subjects) { subject in VStack(alignment:.leading,spacing:10) { Text(subject.semester).font(.caption).foregroundStyle(.secondary); Text(subject.name).font(.headline); Text(subject.kind).font(.caption.bold()).padding(8).background(Color.accentColor.opacity(0.15),in:Capsule()); Text(subject.controls.joined(separator:", ")).font(.subheadline); if let passed = subject.passed { Label(passed ? "Сдано" : "Есть задолженность",systemImage:passed ? "checkmark.circle" : "exclamationmark.circle") }; Text(subject.results.joined(separator:", ")) }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:24)) } }
                if tab == "alerts" {
                    if let count = account.snapshot.unread,count > 0 { Text("Непрочитанных в личном кабинете: \(count)").font(.caption).foregroundStyle(.secondary) }
                    ForEach(account.snapshot.noticeItems ?? []) { item in Link(destination:URL(string:"https://lks.siriusuniversity.ru/dashboard")!) { VStack(alignment:.leading,spacing:4) { Text(item.title).font(.headline); if !item.text.isEmpty { Text(item.text).font(.subheadline).foregroundStyle(.secondary) }; if !item.time.isEmpty { Text(item.time).font(.caption).foregroundStyle(.secondary) } }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:24)) }.buttonStyle(.plain) }
                    if (account.snapshot.noticeItems ?? []).isEmpty { Text(account.snapshot.noticeItems == nil ? "Обновите данные личного кабинета" : "Уведомлений нет.").foregroundStyle(.secondary) }
                }
                if tab == "news" {
                    ForEach(account.snapshot.newsItems ?? []) { item in Link(destination:URL(string:"https://lks.siriusuniversity.ru/news/show/" + item.id)!) { VStack(alignment:.leading,spacing:6) { Text(item.title).font(.body).lineLimit(4); if !item.date.isEmpty { Text(String(item.date.prefix(16))).font(.caption).foregroundStyle(.secondary) } }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:24)) }.buttonStyle(.plain) }
                    if (account.snapshot.newsItems ?? []).isEmpty { Text(account.snapshot.newsItems == nil ? "Обновите данные личного кабинета" : "Новостей нет.").foregroundStyle(.secondary) }
                }
                Toggle("Уведомления об оценках",isOn:$alerts)
                Button("Войти снова") { account.open(); login = true }
                Button("Отключить личный кабинет",role:.destructive) { Task { await account.disconnect() } }
            }
        }.padding(18) }.sheet(isPresented:$login) { NavigationStack { AccountBrowser(web:account.browser).toolbar { Button("Готово") { login = false; Task { await account.refresh() } } } } }.tint(themeColor(theme,custom:custom)) }
    }
    func tabButton(_ key: String,_ title: String) -> some View { Button { tab = key } label: { Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal,14).padding(.vertical,12).background(tab == key ? Color.accentColor.opacity(0.2) : .clear,in:Capsule()) }.buttonStyle(.plain) }
    @State private var attendanceOpen = false
    var gradesContent: some View {
        VStack(alignment:.leading,spacing:8) {
            let values = marks.compactMap(\.grade)
            let recorded = marks.filter { $0.absent != nil }
            HStack(spacing:8) {
                stat(values.isEmpty ? "—" : String(format:"%.1f",values.reduce(0,+)/Double(values.count)),"средний балл")
                Button { attendanceOpen = true } label: { stat(recorded.isEmpty ? "—" : "\(Int((Double(recorded.filter { $0.absent == false }.count)*100/Double(recorded.count)).rounded())) %","посещаемость ›") }.buttonStyle(.plain)
                Button { attendanceOpen = true } label: { stat("\(marks.filter { $0.absent == true }.count)","пропусков ›") }.buttonStyle(.plain)
            }.padding(.bottom,8)
            let homework = marks.filter { !($0.homework ?? "").isEmpty && journalDate($0.date).map { $0 >= Calendar.current.startOfDay(for:Date()).addingTimeInterval(-7*86400) } == true }.sorted { (journalDate($0.date) ?? .distantPast) < (journalDate($1.date) ?? .distantPast) }
            if !homework.isEmpty {
                Text("Домашние задания").font(.headline).padding(.top,12).padding(.bottom,4)
                ForEach(Array(homework.enumerated()),id:\.element.id) { index,mark in VStack(alignment:.leading,spacing:3) { Text(mark.discipline).font(.subheadline.weight(.semibold)); Text(mark.homework ?? "").font(.body); Text("Задано " + shortJournalDate(mark.date) + " · " + mark.type).font(.caption).foregroundStyle(.secondary) }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:UnevenRoundedRectangle(topLeadingRadius:index == 0 ? 24 : 4,bottomLeadingRadius:index == homework.count-1 ? 24 : 4,bottomTrailingRadius:index == homework.count-1 ? 24 : 4,topTrailingRadius:index == 0 ? 24 : 4)) }
            }
            Text("По дисциплинам").font(.headline).padding(.top,16).padding(.bottom,4)
            let names = Array(Set(marks.map(\.discipline))).sorted()
            ForEach(Array(names.enumerated()),id:\.element) { index,name in OriginalDisciplineCard(name:name,marks:marks.filter { $0.discipline == name },first:index == 0,last:index == names.count-1) }
        }.sheet(isPresented:$attendanceOpen) { NavigationStack { List { ForEach(Array(Set(marks.map(\.discipline))).sorted(),id:\.self) { name in Section(name) { let items = marks.filter { $0.discipline == name }; Text("Пропусков: \(items.filter { $0.absent == true }.count)"); ForEach(items.filter { $0.absent == true }.sorted { (journalDate($0.date) ?? .distantPast) > (journalDate($1.date) ?? .distantPast) }) { mark in Text(shortJournalDate(mark.date) + " · " + (mark.time ?? "") + " · " + mark.type) } } } }.navigationTitle("Посещаемость").toolbar { Button("Готово") { attendanceOpen = false } } } }
    }
    func stat(_ value: String,_ label: String) -> some View { VStack(alignment:.leading,spacing:6) { Text(value).font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor); Text(label).font(.caption).foregroundStyle(.secondary) }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:22)) }
}

func journalDate(_ text: String) -> Date? { let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(identifier:"Europe/Moscow"); for pattern in ["dd.MM.yyyy","yyyy-MM-dd"] { f.dateFormat = pattern; if let date = f.date(from:text) { return date } }; return nil }
func shortJournalDate(_ text: String) -> String { guard let date = journalDate(text) else { return text }; let f = DateFormatter(); f.locale = Locale(identifier:"ru_RU"); f.dateFormat = "d MMM"; return f.string(from:date) }
struct GradePill: View {
    let value: Double?
    var text: String? = nil
    var absent = false
    var body: some View {
        let five = (value ?? 0) > 10 ? (value ?? 0)/20 : ((value ?? 0) > 5 ? (value ?? 0)/2 : (value ?? 0))
        let color: Color = absent || five < 2.5 ? .red : five >= 4.5 ? .accentColor : five >= 3.5 ? Color(hex:0xD9AF58) : Color(hex:0xA6B6C4)
        Text(text ?? value?.formatted() ?? "Н").font(.caption.weight(.semibold)).foregroundStyle(color).padding(.horizontal,10).padding(.vertical,4).background(color.opacity(0.16),in:Capsule())
    }
}
struct GradeFlow: Layout {
    func positions(_ subviews: Subviews, width: CGFloat) -> ([CGPoint],CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for item in subviews { let size = item.sizeThatFits(.unspecified); if x > 0 && x + size.width > width { x = 0; y += row + 6; row = 0 }; points.append(CGPoint(x:x,y:y)); x += size.width + 6; row = max(row,size.height) }
        return (points,CGSize(width:width,height:y+row))
    }
    func sizeThatFits(proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) -> CGSize { positions(subviews,width:proposal.width ?? 300).1 }
    func placeSubviews(in bounds: CGRect,proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) { let points = positions(subviews,width:bounds.width).0; for (index,item) in subviews.enumerated() { item.place(at:CGPoint(x:bounds.minX+points[index].x,y:bounds.minY+points[index].y),proposal:.unspecified) } }
}
struct OriginalDisciplineCard: View {
    let name: String
    let marks: [JournalMark]
    let first: Bool
    let last: Bool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var ordered: [JournalMark] { marks.sorted { let a = journalDate($0.date) ?? .distantPast,b = journalDate($1.date) ?? .distantPast; return a == b ? ($0.time ?? "") < ($1.time ?? "") : a < b } }
    var body: some View {
        let grades = ordered.compactMap(\.grade)
        let recorded = marks.filter { $0.absent != nil }
        VStack(alignment:.leading,spacing:8) {
            Button { withAnimation(reduceMotion ? nil : .spring(response:0.3,dampingFraction:0.9)) { expanded.toggle() } } label: {
                HStack(spacing:12) {
                    VStack(alignment:.leading,spacing:4) {
                        Text(name).font(.headline).lineLimit(2)
                        Text("\(grades.count) оценок" + (recorded.isEmpty ? "" : " · посещаемость \(Int((Double(recorded.filter { $0.absent == false }.count)*100/Double(recorded.count)).rounded())) %") + (marks.contains { $0.absent == true } ? " · пропусков \(marks.filter { $0.absent == true }.count)" : "")).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    if !grades.isEmpty { GradePill(value:grades.reduce(0,+)/Double(grades.count),text:String(format:"%.1f",grades.reduce(0,+)/Double(grades.count))) }
                    Image(systemName:"chevron.down").font(.caption).rotationEffect(.degrees(expanded ? 180 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(name + (expanded ? ", свернуть" : ", все занятия"))
            if !grades.isEmpty { GradeFlow { ForEach(Array(grades.suffix(12).enumerated()),id:\.offset) { _,grade in GradePill(value:grade) } } }
            if expanded { ForEach(ordered) { mark in
                HStack(alignment:.top,spacing:12) {
                    VStack(alignment:.leading,spacing:3) { Text(shortJournalDate(mark.date)).font(.caption.weight(.semibold)); if let time = mark.time { Text(time).font(.caption).foregroundStyle(.secondary) } }.frame(width:56,alignment:.leading)
                    VStack(alignment:.leading,spacing:3) { Text(mark.type).font(.subheadline); if let topic = mark.topic,!topic.isEmpty { Text("Тема: " + topic).font(.caption).foregroundStyle(.secondary) }; if let homework = mark.homework,!homework.isEmpty { Text("ДЗ: " + homework).font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth:.infinity,alignment:.leading)
                    if let grade = mark.grade { GradePill(value:grade) } else if mark.absent == true { GradePill(value:nil,absent:true) } else if mark.absent == false { Text("был").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical,5)
            } }
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:UnevenRoundedRectangle(topLeadingRadius:first ? 24 : 4,bottomLeadingRadius:last ? 24 : 4,bottomTrailingRadius:last ? 24 : 4,topTrailingRadius:first ? 24 : 4))
    }
}
