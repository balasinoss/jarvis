import Foundation
import Security

/// All user settings. API keys live in the iOS Keychain (encrypted, never leave the phone
/// except to call Google/Anthropic). Everything else is in UserDefaults.
@MainActor
final class Settings: ObservableObject {
  static let shared = Settings()

  enum Language: String, CaseIterable, Identifiable {
    case greek = "el"
    case english = "en"
    case auto = "auto"
    var id: String { rawValue }
    var label: String {
      switch self {
      case .greek: return "Ελληνικά"
      case .english: return "English"
      case .auto: return "Ό,τι μιλάω"
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

  private let defaults = UserDefaults.standard

  private init() {
    geminiKey = Keychain.get("geminiKey") ?? ""
    claudeKey = Keychain.get("claudeKey") ?? ""
    let d = UserDefaults.standard
    geminiModel = d.string(forKey: "geminiModel") ?? "gemini-3.8-live"
    geminiVoice = d.string(forKey: "geminiVoice") ?? "Kore"
    claudeModel = d.string(forKey: "claudeModel") ?? "claude-sonnet-5-5"
    language = Language(rawValue: d.string(forKey: "language") ?? "") ?? .greek
    visionEngine = VisionEngine(rawValue: d.string(forKey: "visionEngine") ?? "") ?? .live
    halfDuplex = d.object(forKey: "halfDuplex") as? Bool ?? false
    liveCamera = d.object(forKey: "liveCamera") as? Bool ?? false
    claudeWebSearch = d.object(forKey: "claudeWebSearch") as? Bool ?? true
    geminiSearch = d.object(forKey: "geminiSearch") as? Bool ?? false
    idleMinutes = d.object(forKey: "idleMinutes") as? Int ?? 5
    allowPhoneMic = d.object(forKey: "allowPhoneMic") as? Bool ?? true
    wakeWord = d.object(forKey: "wakeWord") as? Bool ?? true
    echoCancellation = d.object(forKey: "echoCancellation") as? Bool ?? false
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
