import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

struct MicrosoftTokens: Codable { var access: String; var refresh: String; var expires: Date }
enum TokenVault {
    static let service = "com.rassvet.lecturial2.microsoft"
    static func read() -> MicrosoftTokens? {
        var result: CFTypeRef?
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"tokens",kSecReturnData as String:true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(MicrosoftTokens.self, from: data)
    }
    static func save(_ tokens: MicrosoftTokens?) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"tokens"]
        guard let tokens else { SecItemDelete(query as CFDictionary); return }
        let data = try JSONEncoder().encode(tokens)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw URLError(.cannotWriteToFile) }
        } else if status != errSecSuccess { throw URLError(.cannotWriteToFile) }
    }
}
@MainActor final class OutlookSync: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OutlookSync()
    let clientID = "7b4fd77a-2e0e-4224-9b1e-6d67baaebfc6"
    let redirect = "com.rassvet.lecturial2://oauth"
    let authority = "https://login.microsoftonline.com/common/oauth2/v2.0/"
    @Published var status = ""
    @Published var busy = false
    @Published var connected = TokenVault.read() != nil
    var web: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func encoded(_ fields: [String:String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.sorted { $0.key < $1.key }.map { $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
    }
    func token(_ fields: [String:String], previous: String = "") async throws -> MicrosoftTokens {
        var values = fields; values["client_id"] = clientID; values["scope"] = "offline_access User.Read Calendars.ReadWrite"
        var request = URLRequest(url: URL(string: authority + "token")!); request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = Data(encoded(values).utf8)
        let (data,response) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String:Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else { throw NSError(domain: "Microsoft", code: 1, userInfo: [NSLocalizedDescriptionKey: json["error_description"] as? String ?? "Не удалось войти в Microsoft"]) }
        let tokens = MicrosoftTokens(access: access, refresh: json["refresh_token"] as? String ?? previous, expires: Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600)-60))
        try TokenVault.save(tokens); connected = true; return tokens
    }
    func signIn() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let verifier = UUID().uuidString + UUID().uuidString
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let state = UUID().uuidString
            let url = URL(string: authority + "authorize?" + encoded(["client_id":clientID,"response_type":"code","redirect_uri":redirect,"response_mode":"query","scope":"offline_access User.Read Calendars.ReadWrite","state":state,"code_challenge":challenge,"code_challenge_method":"S256","prompt":"select_account"]))!
            let callback: URL = try await withCheckedThrowingContinuation { continuation in
                web = ASWebAuthenticationSession(url: url, callbackURLScheme: "com.rassvet.lecturial2") { url,error in
                    if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? URLError(.cancelled)) }
                }
                web?.presentationContextProvider = self
                if web?.start() != true { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
            }
            let fields = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard fields.first(where: { $0.name == "state" })?.value == state, let code = fields.first(where: { $0.name == "code" })?.value else { throw URLError(.userAuthenticationRequired) }
            _ = try await token(["grant_type":"authorization_code","code":code,"redirect_uri":redirect,"code_verifier":verifier]); status = "Подключено"
        } catch { status = error.localizedDescription }
        web = nil
    }
    func graph(_ method: String, _ path: String, body: [String:Any]? = nil, retry: Bool = true) async throws -> [String:Any] {
        guard var tokens = TokenVault.read() else { throw URLError(.userAuthenticationRequired) }
        if tokens.expires < Date() { tokens = try await token(["grant_type":"refresh_token","refresh_token":tokens.refresh], previous: tokens.refresh) }
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0" + path)!); request.httpMethod = method; request.setValue("Bearer " + tokens.access, forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data,response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && retry { _ = try await token(["grant_type":"refresh_token","refresh_token":tokens.refresh], previous: tokens.refresh); return try await graph(method,path,body:body,retry:false) }
        guard (200..<300).contains(code) else { throw NSError(domain:"Graph",code:code,userInfo:[NSLocalizedDescriptionKey:"Outlook: HTTP \(code)"]) }
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
    }
    func automatic(lessons: [Lesson], group: String, week: Date) async {
        guard UserDefaults.standard.bool(forKey:"outlookAuto"), connected, !busy else { return }
        await sync(lessons: lessons, group: group, week: week)
    }
    func sync(lessons: [Lesson], group: String, week: Date) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let calendars = try await graph("GET","/me/calendars?$top=100")
            var id = (calendars["value"] as? [[String:Any]])?.first(where: { $0["name"] as? String == "Lecturial 2" })?["id"] as? String
            if id == nil { id = try await graph("POST","/me/calendars",body:["name":"Lecturial 2"])["id"] as? String }
            guard let id, let component = id.addingPercentEncoding(withAllowedCharacters:.alphanumerics) else { throw URLError(.cannotParseResponse) }
            let scope = "outlookMap-" + id + "-" + group
            var mapping = UserDefaults.standard.dictionary(forKey:scope) as? [String:String] ?? [:]
            let weekKey = "outlookWeek-" + id + "-" + group + "-" + String(Int(week.timeIntervalSince1970 / 86400))
            let previous = UserDefaults.standard.stringArray(forKey: weekKey) ?? []
            var current: [String] = []
            let f = ISO8601DateFormatter()
            for lesson in lessons {
                guard let start = lesson.begin, let end = lesson.finish else { continue }
                let digest = SHA256.hash(data:Data((group + lesson.id).utf8)).map { String(format:"%02x",$0) }.joined()
                current.append(digest)
                var body: [String:Any] = ["subject":lesson.title,"location":["displayName":lesson.room],"start":["dateTime":f.string(from:start),"timeZone":"UTC"],"end":["dateTime":f.string(from:end),"timeZone":"UTC"],"transactionId":digest]
                if let remote = mapping[digest], let escaped = remote.addingPercentEncoding(withAllowedCharacters:.alphanumerics) { body.removeValue(forKey: "transactionId"); _ = try await graph("PATCH","/me/events/" + escaped,body:body) }
                else { let result = try await graph("POST","/me/calendars/" + component + "/events",body:body); if let remote = result["id"] as? String { mapping[digest] = remote; UserDefaults.standard.set(mapping,forKey:scope) } }
            }
            for removed in previous where !current.contains(removed) {
                if let remote = mapping[removed], let escaped = remote.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                    do { _ = try await graph("DELETE", "/me/events/" + escaped) }
                    catch { if (error as NSError).code != 404 { throw error } }
                    mapping.removeValue(forKey: removed)
                }
            }
            UserDefaults.standard.set(mapping, forKey: scope)
            UserDefaults.standard.set(current, forKey: weekKey)
            status = "Синхронизировано занятий: \(lessons.count)"
        } catch { status = error.localizedDescription }
    }
    func disconnect() { try? TokenVault.save(nil); connected = false; UserDefaults.standard.set(false,forKey:"outlookAuto"); status = "Отключено" }
}
struct OutlookView: View {
    @ObservedObject private var service = OutlookSync.shared
    @AppStorage("outlookAuto") private var automatic = false
    var body: some View { Form {
        Text("Календарь Lecturial 2 в вашей учётной записи Microsoft")
        if service.connected { Toggle("Синхронизировать при обновлении расписания",isOn:$automatic); Button("Отключить",role:.destructive) { service.disconnect() } }
        else { Button("Войти в Microsoft") { Task { await service.signIn() } }.disabled(service.busy) }
        if service.busy { ProgressView() }; Text(service.status)
    }.navigationTitle("Outlook") }
}
