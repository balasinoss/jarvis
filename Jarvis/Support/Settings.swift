import Foundation
import Security

/// All user settings. API keys live in the iOS Keychain (encrypted, never leave the phone
/// except to call Google/Anthropic). Everything else is in UserDefaults.
@MainActor
final class Settings: ObservableObject {
  static let shared = Settings()

  /// Only Greek and English. No automatic switching: Jarvis always answers in this one.
  enum Language: String, CaseIterable, Identifiable {
    case greek = "el"
    case english = "en"
    var id: String { rawValue }
    var label: String { self == .greek ? "Ελληνικά" : "English" }
    /// Locale for the iPhone speech recognizer that writes your words on screen.
    var speechLocale: String { self == .greek ? "el-GR" : "en-US" }
  }

  enum AnswerLength: String, CaseIterable, Identifiable {
    case short, normal, detailed
    var id: String { rawValue }
    var label: String {
      switch self {
      case .short: return "Σύντομες"
      case .normal: return "Κανονικές"
      case .detailed: return "Αναλυτικές"
      }
    }
  }

  enum Tone: String, CaseIterable, Identifiable {
    case friendly, formal, teacher, funny
    var id: String { rawValue }
    var label: String {
      switch self {
      case .friendly: return "Φιλικός"
      case .formal: return "Επίσημος"
      case .teacher: return "Δάσκαλος (εξηγεί)"
      case .funny: return "Με χιούμορ"
      }
    }
  }

  enum VisionEngine: String, CaseIterable, Identifiable {
    case live = "live"
    case claude = "claude"
    var id: String { rawValue }
    var label: String {
      switch self {
      case .live: return "Gemini (γρήγορο)"
      case .claude: return "Claude (πιο ακριβές, πιο αργό)"
      }
    }
  }

  enum CameraQuality: String, CaseIterable, Identifiable {
    case normal, high
    var id: String { rawValue }
    var label: String { self == .normal ? "Κανονική (πιο σταθερή)" : "Υψηλή (για κείμενα)" }
  }

  enum Accent: String, CaseIterable, Identifiable {
    case aurora, ocean, sunset, mint
    var id: String { rawValue }
    var label: String {
      switch self {
      case .aurora: return "Aurora (μωβ-μπλε)"
      case .ocean: return "Ocean (μπλε)"
      case .sunset: return "Sunset (πορτοκαλί)"
      case .mint: return "Mint (πράσινο)"
      }
    }
  }

  static let geminiVoices = ["Kore", "Aoede", "Leda", "Zephyr", "Puck", "Charon", "Fenrir", "Orus"]

  @Published var geminiKey: String { didSet { Keychain.set(geminiKey, for: "geminiKey") } }
  @Published var claudeKey: String { didSet { Keychain.set(claudeKey, for: "claudeKey") } }

  @Published var geminiModel: String { didSet { save("geminiModel", geminiModel) } }
  @Published var geminiVoice: String { didSet { save("geminiVoice", geminiVoice) } }
  @Published var claudeModel: String { didSet { save("claudeModel", claudeModel) } }
  @Published var language: Language { didSet { save("language", language.rawValue) } }
  @Published var visionEngine: VisionEngine { didSet { save("visionEngine", visionEngine.rawValue) } }
  /// Mute the mic while Jarvis is talking (use if he keeps interrupting himself).
  @Published var halfDuplex: Bool { didSet { save("halfDuplex", halfDuplex) } }
  /// Send a camera frame every second while talking (uses more battery on the glasses).
  @Published var liveCamera: Bool { didSet { save("liveCamera", liveCamera) } }
  @Published var claudeWebSearch: Bool { didSet { save("claudeWebSearch", claudeWebSearch) } }
  /// Google Search inside Gemini Live. Not included in Gemini's free tier, so off by default.
  @Published var geminiSearch: Bool { didSet { save("geminiSearch", geminiSearch) } }
  /// Stop automatically after this many minutes of silence (saves battery and free-tier quota).
  @Published var idleMinutes: Int { didSet { save("idleMinutes", idleMinutes) } }
  /// Standby: wait for you to say "Jarvis" (keeps the glasses mic open, like a call).
  @Published var wakeWord: Bool { didSet { save("wakeWord", wakeWord) } }
  /// iPhone echo cancellation on the mic (off by default; can silence Bluetooth mics).
  @Published var echoCancellation: Bool { didSet { save("echoCancellation", echoCancellation) } }
  /// Allow the phone microphone when the glasses are not connected (handy for testing).
  @Published var allowPhoneMic: Bool { didSet { save("allowPhoneMic", allowPhoneMic) } }

  // Preferences
  @Published var answerLength: AnswerLength { didSet { save("answerLength", answerLength.rawValue) } }
  @Published var tone: Tone { didSet { save("tone", tone.rawValue) } }
  /// What Jarvis calls you (empty = no name).
  @Published var userName: String { didSet { save("userName", userName) } }
  /// Free-text instructions added to every conversation ("I study mechanical engineering…").
  @Published var customInstructions: String { didSet { save("customInstructions", customInstructions) } }
  @Published var greetOnStart: Bool { didSet { save("greetOnStart", greetOnStart) } }
  @Published var chime: Bool { didSet { save("chime", chime) } }
  @Published var haptics: Bool { didSet { save("haptics", haptics) } }
  @Published var showDiagnostics: Bool { didSet { save("showDiagnostics", showDiagnostics) } }
  @Published var cameraQuality: CameraQuality { didSet { save("cameraQuality", cameraQuality.rawValue) } }
  @Published var accent: Accent { didSet { save("accent", accent.rawValue) } }
  @Published var expiryReminders: Bool { didSet { save("expiryReminders", expiryReminders) } }

  private let defaults = UserDefaults.standard

  private init() {
    geminiKey = Keychain.get("geminiKey") ?? ""
    claudeKey = Keychain.get("claudeKey") ?? ""
    let d = UserDefaults.standard
    geminiModel = d.string(forKey: "geminiModel") ?? "gemini-3.8-live"
    geminiVoice = d.string(forKey: "geminiVoice") ?? "Kore"
    claudeModel = d.string(forKey: "claudeModel") ?? "claude-sonnet-5-5"
    language = Language(rawValue: d.string(forKey: "language") ?? "") ?? .greek  // old "auto" → Greek
    visionEngine = VisionEngine(rawValue: d.string(forKey: "visionEngine") ?? "") ?? .live
    halfDuplex = d.object(forKey: "halfDuplex") as? Bool ?? false
    liveCamera = d.object(forKey: "liveCamera") as? Bool ?? false
    claudeWebSearch = d.object(forKey: "claudeWebSearch") as? Bool ?? true
    geminiSearch = d.object(forKey: "geminiSearch") as? Bool ?? false
    idleMinutes = d.object(forKey: "idleMinutes") as? Int ?? 5
    allowPhoneMic = d.object(forKey: "allowPhoneMic") as? Bool ?? true
    wakeWord = d.object(forKey: "wakeWord") as? Bool ?? true
    echoCancellation = d.object(forKey: "echoCancellation") as? Bool ?? false
    answerLength = AnswerLength(rawValue: d.string(forKey: "answerLength") ?? "") ?? .detailed
    tone = Tone(rawValue: d.string(forKey: "tone") ?? "") ?? .friendly
    userName = d.string(forKey: "userName") ?? ""
    customInstructions = d.string(forKey: "customInstructions") ?? ""
    greetOnStart = d.object(forKey: "greetOnStart") as? Bool ?? true
    chime = d.object(forKey: "chime") as? Bool ?? true
    haptics = d.object(forKey: "haptics") as? Bool ?? true
    showDiagnostics = d.object(forKey: "showDiagnostics") as? Bool ?? false
    cameraQuality = CameraQuality(rawValue: d.string(forKey: "cameraQuality") ?? "") ?? .normal
    accent = Accent(rawValue: d.string(forKey: "accent") ?? "") ?? .aurora
    expiryReminders = d.object(forKey: "expiryReminders") as? Bool ?? true
  }

  var hasGeminiKey: Bool { !geminiKey.trimmingCharacters(in: .whitespaces).isEmpty }
  var hasClaudeKey: Bool { !claudeKey.trimmingCharacters(in: .whitespaces).isEmpty }

  private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
}

enum Keychain {
  private static let service = "com.jarvis.glasses"

  static func set(_ value: String, for account: String) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var add = base
    add[kSecValueData as String] = Data(trimmed.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(add as CFDictionary, nil)
  }

  static func get(_ account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
