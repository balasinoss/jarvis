import Foundation
@preconcurrency import UserNotifications

/// Free Apple ID installs stop working after 7 days. Sideloadly puts a "provisioning profile"
/// inside the app that contains the exact expiry date; we read it and remind you in time.
@MainActor
final class SideloadExpiry: ObservableObject {
  static let shared = SideloadExpiry()

  @Published private(set) var expiryDate: Date?

  private init() {
    expiryDate = Self.readExpiry()
  }

  var daysLeft: Double? {
    guard let expiryDate else { return nil }
    return expiryDate.timeIntervalSinceNow / 86_400
  }

  /// "σε 2 μέρες και 5 ώρες" / "σε 3 ώρες" / "έληξε".
  var remainingText: String {
    guard let expiryDate else { return "άγνωστη" }
    let seconds = expiryDate.timeIntervalSinceNow
    if seconds <= 0 { return "έληξε" }
    let hours = Int(seconds / 3600)
    if hours < 24 { return "σε \(max(hours, 1)) ώρ\(hours == 1 ? "α" : "ες")" }
    let days = hours / 24
    let rest = hours % 24
    return "σε \(days) μέρ\(days == 1 ? "α" : "ες")" + (rest > 0 ? " και \(rest) ώρ\(rest == 1 ? "α" : "ες")" : "")
  }

  var dateText: String {
    guard let expiryDate else { return "—" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "el_GR")
    f.dateFormat = "EEEE d MMM, HH:mm"
    return f.string(from: expiryDate)
  }

  /// True when it's time to show a warning in the app (less than 2 days left).
  var isSoon: Bool { (daysLeft ?? 99) < 2 }

  /// Schedules "renew Jarvis" notifications 2 days, 1 day and 3 hours before expiry.
  func scheduleReminders(enabled: Bool) {
    let center = UNUserNotificationCenter.current()
    let ids = ["jarvis.expiry.48h", "jarvis.expiry.24h", "jarvis.expiry.3h"]
    center.removePendingNotificationRequests(withIdentifiers: ids)
    guard enabled, let expiryDate else { return }

    let plan: [(String, TimeInterval, String)] = [
      (ids[0], 48 * 3600, "Ο Jarvis λήγει σε 2 μέρες"),
      (ids[1], 24 * 3600, "Ο Jarvis λήγει αύριο"),
      (ids[2], 3 * 3600, "Ο Jarvis λήγει σε 3 ώρες"),
    ]
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      guard granted else { return }
      for (id, before, title) in plan {
        let fire = expiryDate.addingTimeInterval(-before)
        guard fire > Date() else { continue }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body =
          "Σύνδεσε το iPhone στον υπολογιστή (ή στο ίδιο Wi-Fi) και πάτα Start στο Sideloadly με το ίδιο Jarvis-free.ipa. Οι ρυθμίσεις σου μένουν."
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
      }
    }
  }

  /// Reads ExpirationDate from embedded.mobileprovision (a signed file with a plist inside).
  private static func readExpiry() -> Date? {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url),
      let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
    else { return nil }
    let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
    guard
      let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
    else { return nil }
    return plist["ExpirationDate"] as? Date
  }
}
