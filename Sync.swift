import Foundation

/// 家庭共享：把清单放在一个 Supabase 数据库里，几台手机读写同一份。

struct SyncConfig: Equatable {
    var url: String
    var key: String

    static func load() -> SyncConfig? {
        let u = Keychain.get("sbURL")
        let k = Keychain.get("sbKey")
        if u.isEmpty || k.isEmpty { return nil }
        return SyncConfig(url: u, key: k)
    }

    func save() {
        Keychain.set("sbURL", url)
        Keychain.set("sbKey", key)
    }

    static func clear() {
        Keychain.set("sbURL", "")
        Keychain.set("sbKey", "")
    }

    /// 整理用户填的地址和密钥；填得不对时返回 nil
    static func make(url: String, key: String) -> SyncConfig? {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty || k.isEmpty { return nil }
        if !u.lowercased().hasPrefix("http") {
            u = "https://" + u
        }
        while u.hasSuffix("/") {
            u.removeLast()
        }
        if u.hasSuffix("/rest/v1") {
            u = String(u.dropLast(8))
        }
        guard let parsed = URL(string: u), parsed.host != nil else { return nil }
        return SyncConfig(url: u, key: k)
    }

    /// 共享码：把地址和密钥拼成一串，方便发到另一台手机
    var shareCode: String {
        "fridge:" + url + "|" + key
    }

    static func fromShareCode(_ code: String) -> SyncConfig? {
        var c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.hasPrefix("fridge:") {
            c = String(c.dropFirst(7))
        }
        let parts = c.split(separator: "|", maxSplits: 1).map { String($0) }
        guard parts.count == 2 else { return nil }
        return make(url: parts[0], key: parts[1])
    }
}

struct RemoteItem {
    var id: UUID
    var emoji: String
    var name: String
    var qty: Double
    var unit: String
    var zone: String
    var expiryDay: String?
}

enum SyncError: LocalizedError {
    case badAddress
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .badAddress:
            return "项目地址不对，请检查 Project URL。"
        case .server(let code, let message):
            if code == 404 || message.contains("fridge_items") {
                return "没找到数据表或没有权限，请先在 Supabase 的 SQL Editor 里运行建表语句。（\(code) \(message)）"
            }
            if code == 401 || code == 403 {
                return "密钥不对或没有权限，请检查 Publishable key。（\(code) \(message)）"
            }
            return "服务器返回错误 \(code)：\(message)"
        }
    }
}

enum SyncClient {
    private static let table = "fridge_items"

    private struct Row: Decodable {
        let id: String
        let emoji: String?
        let name: String?
        let qty: Double?
        let unit: String?
        let place: String?
        let expiry: String?
    }

    private struct ServerMessage: Decodable {
        let message: String?
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func dayDate(_ day: String) -> Date? {
        dayFormatter.date(from: String(day.prefix(10)))
    }

    private static func makeRequest(_ cfg: SyncConfig, method: String, query: [URLQueryItem], body: Data?, prefer: String?) throws -> URLRequest {
        guard var comps = URLComponents(string: cfg.url + "/rest/v1/" + table) else {
            throw SyncError.badAddress
        }
        if !query.isEmpty {
            comps.queryItems = query
        }
        guard let url = comps.url else {
            throw SyncError.badAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(cfg.key, forHTTPHeaderField: "apikey")
        // 新版 sb_publishable_ 密钥只放在 apikey 里；旧版 anon 密钥（JWT）还要放进 Authorization
        if !cfg.key.hasPrefix("sb_") {
            request.setValue("Bearer " + cfg.key, forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let prefer = prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code < 200 || code >= 300 {
            let message = (try? JSONDecoder().decode(ServerMessage.self, from: data))?.message ?? ""
            throw SyncError.server(code, message)
        }
        return data
    }

    static func fetch(_ cfg: SyncConfig) async throws -> [RemoteItem] {
        let query = [URLQueryItem(name: "select", value: "id,emoji,name,qty,unit,place,expiry")]
        let request = try makeRequest(cfg, method: "GET", query: query, body: nil, prefer: nil)
        let data = try await send(request)
        let rows = try JSONDecoder().decode([Row].self, from: data)
        var result: [RemoteItem] = []
        for row in rows {
            guard let id = UUID(uuidString: row.id) else { continue }
            let zone = allZones.contains(row.place ?? "") ? (row.place ?? "冷藏") : "冷藏"
            var day: String? = nil
            if let e = row.expiry, e.count >= 10 {
                day = String(e.prefix(10))
            }
            result.append(RemoteItem(
                id: id,
                emoji: row.emoji ?? "🥫",
                name: row.name ?? "",
                qty: row.qty ?? 1,
                unit: row.unit ?? "",
                zone: zone,
                expiryDay: day
            ))
        }
        return result
    }

    static func upsert(_ items: [FoodItem], _ cfg: SyncConfig) async throws {
        var rows: [[String: Any]] = []
        for item in items {
            var row: [String: Any] = [
                "id": item.id.uuidString.lowercased(),
                "emoji": item.emoji,
                "name": item.name,
                "qty": item.qty,
                "unit": item.unit,
                "place": item.zone
            ]
            if let expiry = item.expiry {
                row["expiry"] = dayString(expiry)
            } else {
                row["expiry"] = NSNull()
            }
            rows.append(row)
        }
        let body = try JSONSerialization.data(withJSONObject: rows)
        let query = [URLQueryItem(name: "on_conflict", value: "id")]
        let request = try makeRequest(cfg, method: "POST", query: query, body: body,
                                      prefer: "resolution=merge-duplicates,return=minimal")
        _ = try await send(request)
    }

    static func delete(_ ids: [UUID], _ cfg: SyncConfig) async throws {
        var start = 0
        while start < ids.count {
            let end = min(start + 40, ids.count)
            let list = ids[start..<end].map { $0.uuidString.lowercased() }.joined(separator: ",")
            let query = [URLQueryItem(name: "id", value: "in.(" + list + ")")]
            let request = try makeRequest(cfg, method: "DELETE", query: query, body: nil, prefer: "return=minimal")
            _ = try await send(request)
            start = end
        }
    }
}
