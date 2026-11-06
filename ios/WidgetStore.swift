import Foundation

// Resolve the shared group after re-signing; never silently fall back to a private defaults domain.
enum WidgetStore {
    static let originalGroup = "group.com.rassvet.lecturial2"
    static func groups(in data: Data) -> [String] {
        guard let start = data.range(of:Data("<?xml".utf8)),let end = data.range(of:Data("</plist>".utf8),in:start.lowerBound..<data.endIndex),let plist = try? PropertyListSerialization.propertyList(from:data[start.lowerBound..<end.upperBound],format:nil) as? [String:Any],let entitlements = plist["Entitlements"] as? [String:Any] else { return [] }
        return (entitlements["com.apple.security.application-groups"] as? [String] ?? []).filter { $0.lowercased().contains("lecturial") }
    }
    static var candidates: [String] {
        var groups: [String] = []
        let bundles = [Bundle.main.bundleURL,Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()]
        for url in bundles { if let data = try? Data(contentsOf:url.appendingPathComponent("embedded.mobileprovision")) { groups += self.groups(in:data) } }
        groups.append(originalGroup)
        var seen = Set<String>(); return groups.filter { seen.insert($0).inserted }
    }
    static var location: (id: String,url: URL)? {
        for id in candidates { if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:id) { return (id,url) } }
        return nil
    }
    static var defaults: UserDefaults? { location.flatMap { UserDefaults(suiteName:$0.id) } }
    static var snapshotURL: URL? { location?.url.appendingPathComponent("lecturial-widget-v2.json") }
    static func write(_ data: Data) throws {
        guard let url = snapshotURL else { throw NSError(domain:"LecturialWidget",code:1,userInfo:[NSLocalizedDescriptionKey:"Нет доступа к общей группе приложения и виджета. Проверьте подпись App Groups в AltStore."]) }
        try data.write(to:url,options:.atomic)
    }
    static func read() -> Data? { snapshotURL.flatMap { try? Data(contentsOf:$0) } }
}
