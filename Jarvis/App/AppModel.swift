import AVFoundation
import SwiftUI
import UIKit

/// Ties everything together: glasses ↔ audio ↔ Gemini Live ↔ tools/Claude.
@MainActor
final class AppModel: ObservableObject {
  static let shared = AppModel()

  enum Status: Equatable {
    case idle
    case standby
    case connecting
    case listening
    case speaking
    case working(String)
    case error(String)

    var label: String {
      switch self {
      case .idle: return "Ανενεργός"
      case .standby: return "Περιμένω να πεις «Jarvis»"
      case .connecting: return "Συνδέομαι…"
      case .listening: return "Σε ακούω"
      case .speaking: return "Μιλάω"
      case .working(let what): return what
      case .error(let message): return message
      }
    }
  }

  enum Role { case user, assistant, claude, system }

  struct Line: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
    var open: Bool
  }

  @Published private(set) var status: Status = .idle
  @Published private(set) var transcript: [Line] = []
  @Published var lastPhoto: UIImage?
  @Published private(set) var isActive = false
  @Published private(set) var micSource = ""
  @Published private(set) var isStandby = false

  let glasses = GlassesManager()
  let settings = Settings.shared
  private(set) var gemini: GeminiLiveClient? {
    didSet { geminiForAudioThread = gemini }
  }
  nonisolated(unsafe) private let audio = AudioPipeline()
  private let wake = WakeWordListener()
  // Copies read from the audio thread (kept in sync on the main thread).
  nonisolated(unsafe) private var geminiForAudioThread: GeminiLiveClient?
  nonisolated(unsafe) private var halfDuplexSnapshot = false
  private lazy var tools = ToolRouter(app: self)

  private var resumptionHandle: String?
  private var reconnectAttempts = 0
  private var lastActivity = Date()
  private var idleTimer: Timer?
  private var runningToolCalls = 0
  private var userStopped = true

  private init() {
    audio.onMicChunk = Self.makeMicHandler(self)
    audio.onSpeakingChanged = { [weak self] speaking in
      guard let self, self.isActive else { return }
      if speaking {
        self.status = .speaking
      } else if self.runningToolCalls == 0, case .speaking = self.status {
        self.status = .listening
      }
      self.lastActivity = Date()
    }
    wake.onWake = { [weak self] in
      guard let self else { return }
      self.isStandby = false
      self.log(.system, "👂 «Jarvis»")
      self.start(fromWakeWord: true)
    }
  }

  /// Runs on the audio thread, so it is deliberately not tied to the main actor.
  nonisolated private static func makeMicHandler(_ model: AppModel) -> (Data) -> Void {
    return { [weak model] chunk in
      guard let model else { return }
      if model.halfDuplexSnapshot && model.audio.isSpeaking { return }
      model.geminiForAudioThread?.sendAudio(chunk)
    }
  }

  var isReadyToStart: Bool { settings.hasGeminiKey }

  func claude() -> ClaudeClient {
    ClaudeClient(apiKey: settings.claudeKey, model: settings.claudeModel, webSearch: settings.claudeWebSearch)
  }

  // MARK: - Start / stop

  func toggle() {
    isActive ? stop() : start()
  }

  // MARK: - "Jarvis" standby

  /// Starts waiting for "Jarvis" if the setting is on and nothing else is running.
  func enterStandbyIfNeeded() {
    guard settings.wakeWord, settings.hasGeminiKey, !isActive, !isStandby else { return }
    Task {
      guard await AVAudioPermission.request() else {
        status = .error("Χρειάζεται άδεια μικροφώνου (Ρυθμίσεις iPhone → Jarvis).")
        return
      }
      guard await WakeWordListener.requestAuthorization() else {
        status = .error(WakeWordListener.WakeError.notAuthorized.localizedDescription)
        return
      }
      guard settings.wakeWord, !isActive, !isStandby else { return }
      do {
        try wake.start(allowPhoneMic: settings.allowPhoneMic)
        isStandby = true
        status = .standby
        micSource = wake.usingGlassesMic ? "Μικρόφωνο γυαλιών" : "Μικρόφωνο κινητού"
      } catch {
        status = .error(error.localizedDescription)
      }
    }
  }

  /// Called when the standby switch changes.
  func setWakeWord(_ enabled: Bool) {
    settings.wakeWord = enabled
    if enabled {
      enterStandbyIfNeeded()
    } else if isStandby {
      wake.stop(deactivateSession: true)
      isStandby = false
      status = .idle
      micSource = ""
    }
  }

  func start() {
    start(fromWakeWord: false)
  }

  func start(fromWakeWord: Bool) {
    guard !isActive else { return }
    if isStandby {
      wake.stop(deactivateSession: false)
      isStandby = false
    }
    guard settings.hasGeminiKey else {
      status = .error("Βάλε πρώτα το κλειδί Gemini στις Ρυθμίσεις.")
      return
    }
    userStopped = false
    isActive = true
    reconnectAttempts = 0
    resumptionHandle = nil
    halfDuplexSnapshot = settings.halfDuplex
    status = .connecting
    log(.system, "— Νέα συνομιλία —")

    Task {
      guard await AVAudioPjarvission.request() else {
        fail("Χρειάζεται άδεια μικροφώνου (Ρυθμίσεις iPhone → Jarvis).")
        return
      }
      guard isActive else { return }  // user pressed stop while the pjarvission prompt was up
      do {
        try audio.start(allowPhoneMic: settings.allowPhoneMic)
        micSource = audio.usingGlassesMic ? "Μικρόφωνο γυαλιών" : "Μικρόφωνο κινητού"
        audio.playChime()  // "I'm listening"
      } catch {
        fail(error.localizedDescription)
        return
      }
      connectGemini()
      startIdleTimer()
    }
  }

  /// Ends the conversation. If "Jarvis" standby is on, goes back to waiting for the name.
  func stop() {
    let backToStandby = settings.wakeWord && settings.hasGeminiKey
    userStopped = true
    isActive = false
    idleTimer?.invalidate()
    idleTimer = nil
    gemini?.disconnect()
    gemini = nil
    audio.stop(deactivateSession: !backToStandby)
    glasses.stopSession()
    closeOpenLines()
    status = .idle
    micSource = ""
    if backToStandby {
      Task {
        try? await Task.sleep(nanoseconds: 400_000_000)
        enterStandbyIfNeeded()
      }
    }
  }

  /// Lets the goodbye finish playing, then stops.
  func stopAfterGoodbye() {
    Task {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      while audio.isSpeaking { try? await Task.sleep(nanoseconds: 300_000_000) }
      stop()
    }
  }

  private func fail(_ message: String) {
    // Don't loop back into standby after an error; the user restarts it from the switch.
    let wasWake = settings.wakeWord
    settings.wakeWord = false
    stop()
    settings.wakeWord = wasWake
    status = .error(message)
    log(.system, "⚠️ \(message)")
  }

  // MARK: - Gemini

  private func connectGemini() {
    gemini?.disconnect()
    let config = GeminiLiveClient.Config(
      apiKey: settings.geminiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      model: settings.geminiModel,
      voice: settings.geminiVoice,
      systemPrompt: Prompts.liveSystemPrompt(
        language: settings.language, notes: NotesStore.shared.summary(),
        googleSearch: settings.geminiSearch, hasClaude: settings.hasClaudeKey),
      functionDeclarations: ToolRouter.declarations,
      googleSearch: settings.geminiSearch,
      resumptionHandle: resumptionHandle)
    let client = GeminiLiveClient(config: config)
    client.onEvent = { [weak self, weak client] event in
      guard let self, let client, client === self.gemini else { return }
      self.handle(event)
    }
    gemini = client
    client.connect()
  }

  private func handle(_ event: GeminiLiveClient.Event) {
    lastActivity = Date()
    switch event {
    case .ready:
      reconnectAttempts = 0
      status = .listening
      if settings.liveCamera { startLiveCamera() }

    case .audio(let pcm):
      audio.play(pcm24k: pcm)

    case .interrupted:
      audio.flushPlayback()
      closeLine(.assistant)

    case .turnComplete:
      closeOpenLines()

    case .inputTranscript(let text):
      append(.user, text)

    case .outputTranscript(let text):
      append(.assistant, text)

    case .toolCall(let calls):
      for call in calls { run(call) }

    case .toolCallCancelled:
      break

    case .resumptionHandle(let handle):
      resumptionHandle = handle

    case .goingAway:
      // The server rotates connections every few minutes; resume seamlessly.
      if resumptionHandle != nil { connectGemini() }

    case .closed(let reason):
      guard isActive, !userStopped else { return }
      if reconnectAttempts < 3 {
        reconnectAttempts += 1
        status = .connecting
        Task {
          try? await Task.sleep(nanoseconds: UInt64(reconnectAttempts) * 1_000_000_000)
          if self.isActive { self.connectGemini() }
        }
      } else {
        fail(reason ?? "Η σύνδεση χάθηκε.")
      }
    }
  }

  private func run(_ call: GeminiLiveClient.ToolCall) {
    runningToolCalls += 1
    status = .working(call.name == "ask_claude" ? "Ρωτάω τον Claude…" : call.name == "look" ? "Κοιτάζω…" : "Εκτελώ…")
    Task {
      let response = await tools.handle(call)
      runningToolCalls -= 1
      gemini?.sendToolResponse(id: call.id, name: call.name, response: response)
      if runningToolCalls == 0, isActive { status = audio.isSpeaking ? .speaking : .listening }
      lastActivity = Date()
    }
  }

  private func startLiveCamera() {
    Task {
      let ok = await glasses.startLiveFrames { [weak self] image in
        guard let self, let jpeg = image.jpegForAI(maxSide: 768, quality: 0.6) else { return }
        self.gemini?.sendImage(jpeg: jpeg)
      }
      if !ok { log(.system, "⚠️ Ζωντανή κάμερα: \(glasses.lastError ?? "δεν ξεκίνησε")") }
    }
  }

  // MARK: - Idle auto-stop

  private func startIdleTimer() {
    idleTimer?.invalidate()
    lastActivity = Date()
    idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isActive else { return }
        let limit = Double(max(1, self.settings.idleMinutes)) * 60
        if Date().timeIntervalSince(self.lastActivity) > limit, self.runningToolCalls == 0 {
          self.log(.system, "Έκλεισα λόγω αδράνειας.")
          self.stop()
        }
      }
    }
  }

  // MARK: - Transcript

  func log(_ role: Role, _ text: String) {
    closeOpenLines()
    transcript.append(Line(role: role, text: text, open: false))
    trimTranscript()
  }

  func clearTranscript() {
    transcript.removeAll()
  }

  private func append(_ role: Role, _ fragment: String) {
    if let i = transcript.lastIndex(where: { $0.open }), transcript[i].role == role {
      transcript[i].text += fragment
    } else {
      closeOpenLines()
      transcript.append(Line(role: role, text: fragment.trimmingCharacters(in: .whitespaces), open: true))
    }
    trimTranscript()
  }

  private func closeLine(_ role: Role) {
    for i in transcript.indices where transcript[i].open && transcript[i].role == role {
      transcript[i].open = false
    }
  }

  private func closeOpenLines() {
    for i in transcript.indices where transcript[i].open { transcript[i].open = false }
  }

  private func trimTranscript() {
    if transcript.count > 300 { transcript.removeFirst(transcript.count - 300) }
  }
}

enum AVAudioPjarvission {
  static func request() async -> Bool {
    await AVAudioApplication.requestRecordPjarvission()
  }
}
