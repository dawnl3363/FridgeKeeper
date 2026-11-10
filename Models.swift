import Foundation
import SwiftUI
import Security

// MARK: - 食材

struct FoodItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var emoji: String = "🥬"
    var name: String = ""
    var qty: Double = 1
    var unit: String = "个"
    var zone: String = "冷藏"
    var expiry: Date? = nil
    var addedAt: Date = Date()
}

enum Freshness {
    case none, ok, soon, expired

    var color: Color {
        switch self {
        case .none: return .gray
        case .ok: return .green
        case .soon: return .orange
        case .expired: return .red
        }
    }
}

let allZones = ["冷藏", "冷冻", "常温"]

extension FoodItem {
    /// 距离到期还有几天（负数表示已过期），没设保质期时为 nil
    var daysLeft: Int? {
        guard let expiry = expiry else { return nil }
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.startOfDay(for: expiry)
        return cal.dateComponents([.day], from: from, to: to).day
    }

    func freshness(remindDays: Int) -> Freshness {
        guard let d = daysLeft else { return .none }
        if d < 0 { return .expired }
        if d <= remindDays { return .soon }
        return .ok
    }

    var expiryLabel: String {
        guard let d = daysLeft else { return "未设保质期" }
        if d < 0 { return "已过期\(-d)天" }
        if d == 0 { return "今天到期" }
        if d == 1 { return "明天到期" }
        return "还剩\(d)天"
    }

    var qtyText: String {
        if qty.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(qty))
        }
        return String(format: "%.1f", qty)
    }
}

func daysFromNow(_ days: Int) -> Date {
    let cal = Calendar.current
    return cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date())) ?? Date()
}

// MARK: - 数据保存与同步

@MainActor
final class FridgeStore: ObservableObject {
    @Published var items: [FoodItem] = [] {
        didSet {
            save()
            refreshReminders()
            if !applyingRemote {
                trackChanges(from: oldValue)
            }
        }
    }

    @Published var remindDays: Int = 3 {
        didSet {
            UserDefaults.standard.set(remindDays, forKey: "remindDays")
            refreshReminders()
        }
    }

    /// 扫过的购物小票（只保存在这台手机上）
    @Published var receipts: [ReceiptRecord] = [] {
        didSet {
            saveReceipts()
        }
    }

    @Published var syncEnabled: Bool = false
    @Published var syncStatus: String = ""

    private let fileURL: URL
    private let receiptsURL: URL

    // 同步状态
    private var config: SyncConfig?
    private var pendingUpserts: Set<UUID> = []
    private var pendingDeletes: Set<UUID> = []
    private var revision: Int = 0
    private var applyingRemote: Bool = false
    private var syncing: Bool = false
    private var syncAgain: Bool = false
    private var debounce: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("fridge.json")
        receiptsURL = dir.appendingPathComponent("receipts.json")
        let saved = UserDefaults.standard.integer(forKey: "remindDays")
        remindDays = saved > 0 ? saved : 3
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([FoodItem].self, from: data) {
            applyingRemote = true
            items = list
            applyingRemote = false
        }
        if let data = try? Data(contentsOf: receiptsURL),
           let list = try? JSONDecoder().decode([ReceiptRecord].self, from: data) {
            receipts = list
        }
        config = SyncConfig.load()
        syncEnabled = config != nil
        pendingUpserts = FridgeStore.loadIDs("pendingUpserts")
        pendingDeletes = FridgeStore.loadIDs("pendingDeletes")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func saveReceipts() {
        guard let data = try? JSONEncoder().encode(receipts) else { return }
        try? data.write(to: receiptsURL, options: .atomic)
    }

    func addReceipt(_ record: ReceiptRecord) {
        receipts.insert(record, at: 0)
        if receipts.count > 200 {
            receipts.removeLast(receipts.count - 200)
        }
    }

    func refreshReminders() {
        Reminders.reschedule(items: items, remindDays: remindDays)
    }

    func freshness(_ item: FoodItem) -> Freshness {
        item.freshness(remindDays: remindDays)
    }

    func upsert(_ item: FoodItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.append(item)
        }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// 加减数量。减到 0 时移出冰箱，并把被移出的那一项返回，方便撤销。
    @discardableResult
    func changeQty(_ id: UUID, by delta: Double) -> FoodItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let q = max(0, items[i].qty + delta)
        if q <= 0 {
            return items.remove(at: i)
        }
        items[i].qty = q
        return nil
    }

    /// 把拍照认出的食材加进来；名称和位置都相同的直接累加数量。
    func merge(_ scanned: [ScannedItem]) {
        var list = items
        for s in scanned {
            let name = s.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if let i = list.firstIndex(where: { $0.name == name && $0.zone == s.zone }) {
                list[i].qty += s.qty
                if let e = s.expiry {
                    if let old = list[i].expiry {
                        list[i].expiry = min(old, e)
                    } else {
                        list[i].expiry = e
                    }
                }
            } else {
                var item = FoodItem()
                item.emoji = s.emoji
                item.name = name
                item.qty = s.qty
                item.unit = s.unit
                item.zone = s.zone
                item.expiry = s.expiry
                list.append(item)
            }
        }
        items = list
    }

    // MARK: 家庭共享

    var shareCode: String {
        config?.shareCode ?? ""
    }

    /// 连接到共享冰箱。先试着读一次，确认地址和密钥可用，再把本机已有的食材全部上传合并。
    func connectSync(_ cfg: SyncConfig) async throws {
        _ = try await SyncClient.fetch(cfg)
        cfg.save()
        config = cfg
        pendingUpserts = Set(items.map { $0.id })
        pendingDeletes = []
        savePending()
        syncEnabled = true
        syncStatus = "已连接"
        await syncNow()
    }

    /// 断开共享。本机的清单保留，只是不再同步。
    func disconnectSync() {
        debounce?.cancel()
        SyncConfig.clear()
        config = nil
        pendingUpserts = []
        pendingDeletes = []
        savePending()
        syncEnabled = false
        syncStatus = ""
    }

    func syncNow() async {
        guard let cfg = config else { return }
        if syncing {
            syncAgain = true
            return
        }
        syncing = true
        repeat {
            syncAgain = false
            await syncOnce(cfg)
        } while syncAgain && config != nil
        syncing = false
    }

    private func syncOnce(_ cfg: SyncConfig) async {
        do {
            // 1. 先把本机还没上传的改动推上去
            var rounds = 0
            while (!pendingUpserts.isEmpty || !pendingDeletes.isEmpty) && rounds < 3 {
                rounds += 1
                let rev = revision
                let ups = pendingUpserts
                let dels = pendingDeletes
                let rows = items.filter { ups.contains($0.id) }
                if !rows.isEmpty {
                    try await SyncClient.upsert(rows, cfg)
                }
                if !dels.isEmpty {
                    try await SyncClient.delete(Array(dels), cfg)
                }
                // 上传期间如果又有新的改动，就保留待上传标记，下一轮再推
                if rev == revision {
                    pendingUpserts.subtract(ups)
                    pendingDeletes.subtract(dels)
                    savePending()
                }
            }
            if !pendingUpserts.isEmpty || !pendingDeletes.isEmpty {
                syncAgain = true
                return
            }

            // 2. 再把云端的最新清单拉下来
            let rev = revision
            let remote = try await SyncClient.fetch(cfg)
            if config == nil { return }
            if rev == revision && pendingUpserts.isEmpty && pendingDeletes.isEmpty {
                apply(remote)
            }
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            syncStatus = "已同步 " + f.string(from: Date())
        } catch {
            syncStatus = "同步失败：" + error.localizedDescription
        }
    }

    private func apply(_ remote: [RemoteItem]) {
        let localByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [FoodItem] = []
        var changed = remote.count != items.count
        for r in remote {
            let old = localByID[r.id]
            var item = old ?? FoodItem()
            item.id = r.id
            item.emoji = r.emoji
            item.name = r.name
            item.qty = r.qty
            item.unit = r.unit
            item.zone = r.zone
            var oldDay: String? = nil
            if let e = old?.expiry {
                oldDay = SyncClient.dayString(e)
            }
            if oldDay != r.expiryDay {
                item.expiry = r.expiryDay.flatMap { SyncClient.dayDate($0) }
            }
            if old != item {
                changed = true
            }
            next.append(item)
        }
        if changed {
            applyingRemote = true
            items = next
            applyingRemote = false
        }
    }

    private func trackChanges(from old: [FoodItem]) {
        guard config != nil else { return }
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Set(items.map { $0.id })
        var changed = false
        for item in items where oldByID[item.id] != item {
            pendingUpserts.insert(item.id)
            pendingDeletes.remove(item.id)
            changed = true
        }
        for id in oldByID.keys where !newIDs.contains(id) {
            pendingDeletes.insert(id)
            pendingUpserts.remove(id)
            changed = true
        }
        if changed {
            revision += 1
            savePending()
            scheduleSync()
        }
    }

    /// 连续点加减时，等停手 0.6 秒再一起上传
    private func scheduleSync() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            await self?.syncNow()
        }
    }

    private func savePending() {
        UserDefaults.standard.set(pendingUpserts.map { $0.uuidString }, forKey: "pendingUpserts")
        UserDefaults.standard.set(pendingDeletes.map { $0.uuidString }, forKey: "pendingDeletes")
    }

    private static func loadIDs(_ key: String) -> Set<UUID> {
        let list = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(list.compactMap { UUID(uuidString: $0) })
    }
}

// MARK: - 购物记录

struct ReceiptLine: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var qty: Double = 1
    var unit: String = ""
    var price: Double? = nil
}

struct ReceiptRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var store: String = ""
    var date: String = ""
    var total: Double? = nil
    var currency: String = "$"
    var lines: [ReceiptLine] = []
}

func moneyText(_ value: Double?, _ currency: String) -> String {
    guard let value = value else { return "—" }
    return currency + String(format: "%.2f", value)
}

func qtyText(_ qty: Double) -> String {
    if qty.truncatingRemainder(dividingBy: 1) == 0 {
        return String(Int(qty))
    }
    return String(format: "%.2f", qty)
}

// MARK: - 钥匙串（保存密钥）

enum Keychain {
    private static let service = "FridgeKeeper"

    static func get(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        if value.isEmpty { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

let defaultModel = "claude-sonnet-5-5"

func currentModel() -> String {
    let m = (UserDefaults.standard.string(forKey: "model") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return m.isEmpty ? defaultModel : m
}
