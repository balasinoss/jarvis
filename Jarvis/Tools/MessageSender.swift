import Contacts
import MessageUI
import UIKit
import UserNotifications

/// Prepares messages and Shortcuts. iOS never lets a third-party app send an SMS/iMessage
/// or open another app on its own, so:
///  - if the phone is unlocked with Jarvis open, the message opens ready to send (one tap);
///  - otherwise a notification appears, and tapping it opens the ready message.
@MainActor
final class MessageSender: NSObject, MFMessageComposeViewControllerDelegate {
  static let shared = MessageSender()

  enum Action {
    case sms(phone: String, text: String)
    case url(URL)
  }

  private var pending: Action?

  // MARK: - Public

  func prepareMessage(contact: String, text: String, app: String) async -> String {
    let appName = app.lowercased()

    if appName == "viber" {
      // Viber only supports "forward text"; the user picks the contact inside Viber.
      guard let url = URL(string: "viber://forward?text=\(encode(text))") else { return "Σφάλμα URL." }
      return run(.url(url), description: "Viber: \(text)")
    }

    guard let found = await findPhone(for: contact) else {
      return "Δεν βρήκα επαφή «\(contact)» με αριθμό τηλεφώνου στις Επαφές του iPhone."
    }
    let phone = normalize(found.phone)

    if appName == "whatsapp" {
      let digits = phone.filter(\.isNumber)
      guard let url = URL(string: "https://wa.me/\(digits)?text=\(encode(text))") else { return "Σφάλμα URL." }
      return run(.url(url), description: "WhatsApp στον/στην \(found.name): \(text)")
    }
    return run(.sms(phone: phone, text: text), description: "Μήνυμα στον/στην \(found.name): \(text)")
  }

  func prepareShortcut(name: String, input: String?) -> String {
    var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
    var items = [URLQueryItem(name: "name", value: name)]
    if let input, !input.isEmpty {
      items.append(URLQueryItem(name: "input", value: "text"))
      items.append(URLQueryItem(name: "text", value: input))
    }
    components.queryItems = items
    guard let url = components.url else { return "Σφάλμα URL." }
    return run(.url(url), description: "Συντόμευση «\(name)»")
  }

  /// Called when the user taps our notification.
  func performPending() {
    guard let action = pending else { return }
    pending = nil
    // Give the app a moment to come to the foreground before presenting.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.execute(action) }
  }

  // MARK: - Running

  private func run(_ action: Action, description: String) -> String {
    if UIApplication.shared.applicationState == .active {
      execute(action)
      return "Άνοιξε στο κινητό έτοιμο: \(description). Ο χρήστης πρέπει να πατήσει Αποστολή."
    }
    pending = action
    notify(description)
    return "Το κινητό είναι κλειδωμένο ή σε άλλη εφαρμογή. Έστειλα ειδοποίηση: όταν την πατήσει, ανοίγει έτοιμο (\(description))."
  }

  private func execute(_ action: Action) {
    switch action {
    case .url(let url):
      UIApplication.shared.open(url)
    case .sms(let phone, let text):
      guard MFMessageComposeViewController.canSendText() else {
        if let url = URL(string: "sms:\(phone)&body=\(encode(text))") { UIApplication.shared.open(url) }
        return
      }
      let vc = MFMessageComposeViewController()
      vc.recipients = [phone]
      vc.body = text
      vc.messageComposeDelegate = self
      topViewController()?.present(vc, animated: true)
    }
  }

  nonisolated func messageComposeViewController(
    _ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult
  ) {
    DispatchQueue.main.async { controller.dismiss(animated: true) }
  }

  private func notify(_ body: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = "Jarvis — πάτα για αποστολή"
      content.body = body
      content.sound = .default
      content.userInfo = ["jarvisPending": true]
      center.add(UNNotificationRequest(identifier: "jarvis.pending", content: content, trigger: nil))
    }
  }

  // MARK: - Contacts

  private func findPhone(for name: String) async -> (name: String, phone: String)? {
    let store = CNContactStore()
    let granted: Bool
    if CNContactStore.authorizationStatus(for: .contacts) == .authorized {
      granted = true
    } else {
      granted = (try? await store.requestAccess(for: .contacts)) ?? false
    }
    guard granted else { return nil }

    let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey]
      as [CNKeyDescriptor]
    let predicate = CNContact.predicateForContacts(matchingName: name)
    let matches = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
    guard let contact = matches.first(where: { !$0.phoneNumbers.isEmpty }) else { return nil }
    let mobile =
      contact.phoneNumbers.first(where: { $0.label == CNLabelPhoneNumberMobile || $0.label == CNLabelPhoneNumberiPhone })
      ?? contact.phoneNumbers.first!
    let display = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
    return (display.isEmpty ? name : display, mobile.value.stringValue)
  }

  /// Turns "694 123 4567" into "+306941234567" (Greek numbers without a country code).
  private func normalize(_ raw: String) -> String {
    var digits = raw.filter { $0.isNumber || $0 == "+" }
    if digits.hasPrefix("00") { digits = "+" + digits.dropFirst(2) }
    if !digits.hasPrefix("+") && digits.count == 10 && (digits.hasPrefix("69") || digits.hasPrefix("2")) {
      digits = "+30" + digits
    }
    return digits
  }

  private func encode(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? text
  }

  private func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}

extension CharacterSet {
  static let urlQueryValueAllowed: CharacterSet = {
    var set = CharacterSet.urlQueryAllowed
    set.remove(charactersIn: "&+=?#")
    return set
  }()
}
