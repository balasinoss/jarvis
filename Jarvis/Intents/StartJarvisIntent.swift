import AppIntents

/// Lets you start Jarvis with Siri ("Start Jarvis"), Back Tap or the Shortcuts app,
/// without fiddling with the screen.
struct StartJarvisIntent: AppIntent {
  static var title: LocalizedStringResource = "Ξεκίνα τον Jarvis"
  static var description = IntentDescription("Ξεκινά συνομιλία με τον Jarvis στα γυαλιά.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    AppModel.shared.start()
    return .result()
  }
}

struct StopJarvisIntent: AppIntent {
  static var title: LocalizedStringResource = "Σταμάτα τον Jarvis"
  static var openAppWhenRun: Bool = false

  @MainActor
  func perform() async throws -> some IntentResult {
    AppModel.shared.stop()
    return .result()
  }
}

struct JarvisShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartJarvisIntent(),
      phrases: ["Start \(.applicationName)", "Ξεκίνα \(.applicationName)", "Talk to \(.applicationName)"],
      shortTitle: "Ξεκίνα",
      systemImageName: "eyeglasses")
    AppShortcut(
      intent: StopJarvisIntent(),
      phrases: ["Stop \(.applicationName)", "Σταμάτα \(.applicationName)"],
      shortTitle: "Σταμάτα",
      systemImageName: "stop.circle")
  }
}
