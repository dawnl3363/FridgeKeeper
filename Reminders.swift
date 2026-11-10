import Foundation
import UserNotifications

/// 到期提醒：每天早上 9 点，把当天"快到期"和"今天到期"的食材合并成一条通知。
enum Reminders {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func reschedule(items: [FoodItem], remindDays: Int) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        let cal = Calendar.current
        let now = Date()
        var soonByDay: [Date: [String]] = [:]
        var todayByDay: [Date: [String]] = [:]

        for item in items {
            guard let expiry = item.expiry else { continue }
            let expDay = cal.startOfDay(for: expiry)
            if remindDays > 0, let early = cal.date(byAdding: .day, value: -remindDays, to: expDay) {
                soonByDay[early, default: []].append(item.name)
            }
            todayByDay[expDay, default: []].append(item.name)
        }

        let days = Set(soonByDay.keys).union(todayByDay.keys).sorted()
        var count = 0
        for day in days {
            guard let fire = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day), fire > now else { continue }
            var lines: [String] = []
            if let names = todayByDay[day], !names.isEmpty {
                lines.append("今天到期：" + names.joined(separator: "、"))
            }
            if let names = soonByDay[day], !names.isEmpty {
                lines.append("还有\(remindDays)天到期：" + names.joined(separator: "、"))
            }
            if lines.isEmpty { continue }

            let content = UNMutableNotificationContent()
            content.title = "冰箱里有东西快到期了"
            content.body = lines.joined(separator: "\n")
            content.sound = .default

            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: "fridge-\(count)", content: content, trigger: trigger)
            center.add(request)

            count += 1
            if count >= 60 { break }   // 系统最多保留 64 条待发通知
        }
    }
}
