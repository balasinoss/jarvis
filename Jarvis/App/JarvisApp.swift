import MWDATCore
import SwiftUI
import UserNotifications

@main
struct JarvisApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("[Jarvis] Wearables.configure failed: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(AppModel.shared)
        .environmentObject(Settings.shared)
        .onOpenURL { url in
          AppModel.shared.glasses.handleURL(url)
        }
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  // Tapping "Jarvis — πάτα για αποστολή" opens the prepared message.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.notification.request.content.userInfo["jarvisPending"] != nil {
      Task { @MainActor in MessageSender.shared.performPending() }
    }
    completionHandler()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
