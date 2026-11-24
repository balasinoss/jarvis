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
    var utterance: Int? = nil
  }

  @Published private(set) var status: Status = .idle
  @Published private(set) var transcript: [Line] = []
  @Published var lastPhoto: UIImage?
  @Published private(set) var isActive = false
  @Published private(set) var micSource = ""
  @Published private(set) var isStandby = false
  /// One-line live diagnostics (mic level, audio sent/received).
  @Published private(set) var diagnostics = ""
  /// 0…1, drives the animated orb.
  @Published private(set) var micLevel: Double = 0

  let glasses = GlassesManager()
  let settings = Settings.shared
  private(set) var gemini: GeminiLiveClient? {
    didSet { geminiForAudioThread = gemini }
  }
  nonisolated(unsafe) private let audio = AudioPipeline()
  nonisolated(unsafe) private let wake = WakeWordListener()
  /// True while waiting for "Jarvis": mic audio goes to the wake-word recognizer.
  nonisolated(unsafe) private var feedWakeWord = false
  /// Writes your speech on screen in the chosen language (see SpeechTranscriber).
  nonisolated(unsafe) private let transcriber = SpeechTranscriber()
  nonisolated(unsafe) private var feedTranscriber = false
  private var currentUserUtterance: Int?
  private var modelTurnActive = false
  // Copies read from the audio thread (kept in sync on the main thread).
  nonisolated(unsafe) private var geminiForAudioThread: GeminiLiveClient?
  nonisolated(unsafe) private var halfDuplexSnapshot = false
  private lazy var tools = ToolRouter(app: self)

  private var resumptionHandle: String?
  private var reconnectAttempts = 0
  private var lastActivity = Date()
  private var idleTimer: Timer?
  private var diagTimer: Timer?
  private var runningToolCalls = 0
  private var userStopped = true

  private init() {
    audio.onMicChunk = Self.makeMicHandler(self)
    audio.onRawMicBuffer = Self.makeRawHandler(self)
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
      self.feedWakeWord = false
      self.isStandby = false
      self.log(.system, "👂 «Jarvis»")
      self.start(fromWakeWord: true)
    }
    transcriber.onText = { [weak self] text, utterance in
      self?.showUserSpeech(text, utterance: utterance)
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

  nonisolated private static func makeRawHandler(_ model: AppModel) -> (AVAudioPCMBuffer) -> Void {
    return { [weak model] buffer in
      guard let model else { return }
      if model.feedWakeWord { model.wake.append(buffer) }
      // Skip while Jarvis talks, so his own voice isn't written as yours.
      if model.feedTranscriber && !model.audio.isSpeaking { model.transcriber.append(buffer) }
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
        // One shared microphone for standby and conversations: no switching.
        if !audio.isRunning {
          try audio.start(allowPhoneMic: settings.allowPhoneMic, echoCancellation: settings.echoCancellation)
        }
        try wake.start()
        feedWakeWord = true
        isStandby = true
        status = .standby
        micSource = audio.usingGlassesMic ? "Μικρόφωνο γυαλιών" : "Μικρόφωνο κινητού"
        startDiagnostics()
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
      feedWakeWord = false
      wake.stop()
      isStandby = false
      if !isActive { audio.stop(deactivateSession: true) }
      diagTimer?.invalidate()
      diagnostics = ""
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
      feedWakeWord = false
      wake.stop()
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
      guard await AVAudioPermission.request() else {
        fail("Χρειάζεται άδεια μικροφώνου (Ρυθμίσεις iPhone → Jarvis).")
        return
      }
      guard isActive else { return }  // user pressed stop while the permission prompt was up
      do {
        if !audio.isRunning {
          try audio.start(allowPhoneMic: settings.allowPhoneMic, echoCancellation: settings.echoCancellation)
        }
        micSource = audio.usingGlassesMic ? "Μικρόφωνο γυαλιών" : "Μικρόφωνο κινητού"
        if settings.chime { audio.playChime() }  // "I'm listening"
      } catch {
        fail(error.localizedDescription)
        return
      }
      if settings.haptics { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
      if await WakeWordListener.requestAuthorization() {
        transcriber.start(localeIdentifier: settings.language.speechLocale)
        feedTranscriber = true
      }
      currentUserUtterance = nil
      modelTurnActive = false
      glasses.prewarm()  // open the glasses connection now, so "τι βλέπω;" is faster
      connectGemini()
      startIdleTimer()
      startDiagnostics()
    }
  }

  /// Ends the conversation. If "Jarvis" standby is on, goes back to waiting for the name.
  func stop() {
    let backToStandby = settings.wakeWord && settings.hasGeminiKey
    userStopped = true
    isActive = false
    idleTimer?.invalidate()
    idleTimer = nil
    diagTimer?.invalidate()
    diagTimer = nil
    diagnostics = ""
    feedTranscriber = false
    transcriber.stop()
    gemini?.disconnect()
    gemini = nil
    if backToStandby {
      audio.flushPlayback()  // keep the mic running for "Jarvis" standby
    } else {
      audio.stop(deactivateSession: true)
    }
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
        Prompts.Options(
          language: settings.language, answerLength: settings.answerLength, tone: settings.tone,
          userName: settings.userName, customInstructions: settings.customInstructions,
          notes: NotesStore.shared.summary(), googleSearch: settings.geminiSearch,
          hasClaude: settings.hasClaudeKey)),
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
      // Short spoken hello: proves the voice path (Gemini → glasses speakers) works.
      if settings.greetOnStart && reconnectAttempts == 0 && resumptionHandle == nil {
        gemini?.sendText(Prompts.greeting(settings.language))
      }
      if settings.liveCamera { startLiveCamera() }

    case .audio(let pcm):
      beginModelTurn()
      audio.play(pcm24k: pcm)

    case .interrupted:
      audio.flushPlayback()
      closeLine(.assistant)
      modelTurnActive = false

    case .turnComplete:
      closeOpenLines()
      modelTurnActive = false

    case .inputTranscript:
      break  // Gemini's own transcript is unreliable (random languages); the iPhone writes it.

    case .outputTranscript(let text):
      beginModelTurn()
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

  /// Jarvis started answering: your next words go on a new line.
  private func beginModelTurn() {
    guard !modelTurnActive else { return }
    modelTurnActive = true
    currentUserUtterance = nil
    if let i = transcript.lastIndex(where: { $0.role == .user && $0.open }) { transcript[i].open = false }
    transcriber.nextUtterance()
  }

  /// Live text of what the user is saying (replaces the line as words are recognized).
  private func showUserSpeech(_ text: String, utterance: Int) {
    guard isActive else { return }
    lastActivity = Date()
    if utterance == currentUserUtterance,
      let i = transcript.lastIndex(where: { $0.utterance == utterance })
    {
      transcript[i].text = text
      return
    }
    currentUserUtterance = utterance
    // Keep Jarvis's current line open if he is still talking; otherwise close everything.
    if let i = transcript.lastIndex(where: { $0.role == .user && $0.open }) { transcript[i].open = false }
    var line = Line(role: .user, text: text, open: true)
    line.utterance = utterance
    // Show the question before Jarvis's answer when the answer already started.
    transcript.append(line)
    trimTranscript()
  }

  // MARK: - On-screen diagnostics

  private func startDiagnostics() {
    diagTimer?.invalidate()
    diagTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isActive || self.isStandby else { return }
        let target = Double(min(1, self.audio.micLevel * 4))
        self.micLevel = self.micLevel * 0.6 + target * 0.4
        let source = self.audio.fellBackToPhoneMic
          ? "Μικρόφωνο κινητού (τα γυαλιά έστελναν σιωπή)"
          : (self.audio.usingGlassesMic ? "Μικρόφωνο γυαλιών" : "Μικρόφωνο κινητού")
        if self.micSource != source { self.micSource = source }
        guard self.settings.showDiagnostics else {
          if !self.diagnostics.isEmpty { self.diagnostics = "" }
          return
        }
        let level = Int(min(1, self.audio.micLevel * 4) * 10)
        let bars = String(repeating: "▮", count: level) + String(repeating: "▯", count: 10 - level)
        let sentSeconds = Double(self.gemini?.audioChunksSent ?? 0) / 10
        let received = self.gemini?.audioChunksReceived ?? 0
        let messages = self.gemini?.messagesReceived ?? 0
        self.diagnostics =
          "🎙️ \(self.audio.isSilent ? "🔇" : "")\(bars)  ήχος: \(self.audio.tapBuffers)  →Gemini: \(String(format: "%.0f", sentSeconds))δ  ←απαντήσεις: \(messages)/\(received)  ↻\(self.audio.restarts)"
          + (self.isStandby ? "\n👂 άκουσα: \(self.wake.lastHeard)" : "")
      }
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

enum AVAudioPermission {
  static func request() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }
}
