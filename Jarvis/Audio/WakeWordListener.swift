import AVFoundation
import Foundation
import Speech

/// Standby mode: listens through the glasses mic for the word "Jarvis" and calls `onWake`.
///
/// Recognition runs on the iPhone itself (Apple's on-device speech recognizer). No audio
/// is sent anywhere while waiting, and the AI only starts after you say "Jarvis".
final class WakeWordListener {
  enum WakeError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case glassesMicMissing
    case noMicrophone
    var errorDescription: String? {
      switch self {
      case .notAuthorized: return "Χρειάζεται άδεια «Αναγνώριση ομιλίας» (Ρυθμίσεις iPhone → Jarvis)."
      case .recognizerUnavailable: return "Η αναγνώριση ομιλίας δεν είναι διαθέσιμη αυτή τη στιγμή."
      case .glassesMicMissing: return "Τα γυαλιά δεν είναι συνδεδεμένα με Bluetooth στο κινητό."
      case .noMicrophone: return "Δεν βρέθηκε μικρόφωνο."
      }
    }
  }

  /// Called on the main thread when "Jarvis" is heard.
  var onWake: (() -> Void)?

  private(set) var isRunning = false
  private(set) var usingGlassesMic = false

  // The English recognizer spells the name the way we match it below.
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var engine = AVAudioEngine()
  private var allowPhoneMic = true
  private var lastTapDate = Date()
  private var lastRebuild = Date.distantPast
  private var watchdog: Timer?
  private var engineObserver: NSObjectProtocol?
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var restartTimer: Timer?
  private var generation = 0
  private var interruptionObserver: NSObjectProtocol?

  /// Spellings the recognizer commonly produces for "Jarvis".
  private let triggers = ["jarvis", "jervis", "javis", "jarvas", "jarvys", "jarviss", "charvis"]

  static func requestAuthorization() async -> Bool {
    if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  func start(allowPhoneMic: Bool) throws {
    guard !isRunning else { return }
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw WakeError.notAuthorized }
    guard let recognizer, recognizer.isAvailable else { throw WakeError.recognizerUnavailable }

    self.allowPhoneMic = allowPhoneMic
    try configureSession()
    try buildEngine()
    isRunning = true
    lastTapDate = Date()
    beginRecognition()
    startWatchdog()

    // After a phone call or Siri, pick up listening again.
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, self.isRunning,
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        AVAudioSession.InterruptionType(rawValue: raw) == .ended
      else { return }
      self.lastRebuild = .distantPast
      self.rebuildEngine()
    }
  }

  // MARK: - Engine (rebuilt whenever Bluetooth renegotiates and the mic goes quiet)

  private func configureSession() throws {
    let session = AVAudioSession.sharedInstance()
    // mixWithOthers: music from other apps keeps playing while Jarvis waits.
    try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
    try session.setActive(true)
    if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
      try? session.setPreferredInput(glasses)
    }
    usingGlassesMic = session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    if !usingGlassesMic && !allowPhoneMic { throw WakeError.glassesMicMissing }
  }

  private func buildEngine() throws {
    let newEngine = AVAudioEngine()
    let input = newEngine.inputNode
    var format = input.outputFormat(forBus: 0)
    var attempts = 0
    while (format.sampleRate <= 0 || format.channelCount == 0) && attempts < 15 {
      Thread.sleep(forTimeInterval: 0.1)
      format = input.outputFormat(forBus: 0)
      attempts += 1
    }
    guard format.sampleRate > 0, format.channelCount > 0 else { throw WakeError.noMicrophone }
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      self.lastTapDate = Date()
      self.lock.lock()
      let current = self.request
      self.lock.unlock()
      current?.append(buffer)
    }
    newEngine.prepare()
    try newEngine.start()
    engine = newEngine
    if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
    engineObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
    ) { [weak self] _ in
      self?.rebuildEngine()
    }
  }

  private func tearDownEngine() {
    if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
    engineObserver = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }

  private func rebuildEngine() {
    guard isRunning, Date().timeIntervalSince(lastRebuild) > 1 else { return }
    lastRebuild = Date()
    tearDownEngine()
    try? AVAudioSession.sharedInstance().setActive(true)
    if let glasses = AVAudioSession.sharedInstance().availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
      try? AVAudioSession.sharedInstance().setPreferredInput(glasses)
    }
    try? buildEngine()
    lastTapDate = Date()
    beginRecognition()
  }

  private func startWatchdog() {
    watchdog?.invalidate()
    watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self, self.isRunning else { return }
      if Date().timeIntervalSince(self.lastTapDate) > 1.5 { self.rebuildEngine() }
    }
  }

  /// `deactivateSession: false` keeps the audio session alive so the conversation can
  /// start immediately (also while the phone is locked).
  func stop(deactivateSession: Bool) {
    guard isRunning else { return }
    isRunning = false
    generation += 1
    if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    interruptionObserver = nil
    restartTimer?.invalidate()
    restartTimer = nil
    lock.lock()
    request?.endAudio()
    request = nil
    lock.unlock()
    task?.cancel()
    task = nil
    watchdog?.invalidate()
    watchdog = nil
    tearDownEngine()
    if deactivateSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  // MARK: - Recognition loop

  private func beginRecognition() {
    guard isRunning, let recognizer else { return }
    generation += 1
    let myGeneration = generation

    task?.cancel()
    let newRequest = SFSpeechAudioBufferRecognitionRequest()
    newRequest.shouldReportPartialResults = true
    newRequest.contextualStrings = ["Jarvis", "Hey Jarvis"]
    newRequest.taskHint = .search
    if recognizer.supportsOnDeviceRecognition {
      newRequest.requiresOnDeviceRecognition = true  // nothing leaves the phone while waiting
    }
    lock.lock()
    request?.endAudio()
    request = newRequest
    lock.unlock()

    task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
      guard let self else { return }
      if let text = result?.bestTranscription.formattedString.lowercased(),
        self.triggers.contains(where: { text.contains($0) })
      {
        DispatchQueue.main.async {
          guard self.isRunning, myGeneration == self.generation else { return }
          self.stop(deactivateSession: false)
          self.onWake?()
        }
        return
      }
      if error != nil || result?.isFinal == true {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          guard self.isRunning, myGeneration == self.generation else { return }
          self.beginRecognition()
        }
      }
    }

    // Start a fresh recognition every 45 s so it never hits Apple's time limits and old
    // words don't pile up in the transcript.
    restartTimer?.invalidate()
    restartTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
      guard let self, self.isRunning, myGeneration == self.generation else { return }
      self.beginRecognition()
    }
  }
}
