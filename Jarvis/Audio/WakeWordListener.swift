import AVFoundation
import Foundation
import Speech

/// Standby mode: listens for the word "Jarvis" and calls `onWake`.
///
/// It doesn't own a microphone: the app's single AudioPipeline feeds it the same mic audio
/// used for conversations (`append`), so there is no switching between audio setups that
/// confuses the Bluetooth connection to the glasses.
///
/// Recognition runs on the iPhone itself (Apple's on-device speech recognizer when
/// available). No audio is sent to Google or Anthropic while waiting.
final class WakeWordListener {
  enum WakeError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    var errorDescription: String? {
      switch self {
      case .notAuthorized: return "Χρειάζεται άδεια «Αναγνώριση ομιλίας» (Ρυθμίσεις iPhone → Jarvis)."
      case .recognizerUnavailable: return "Η αναγνώριση ομιλίας δεν είναι διαθέσιμη αυτή τη στιγμή."
      }
    }
  }

  /// Called on the main thread when "Jarvis" is heard.
  var onWake: (() -> Void)?

  private(set) var isRunning = false
  /// Last words the recognizer heard (shown on screen to help with debugging).
  private(set) var lastHeard = ""

  // The English recognizer spells the name the way we match it below.
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var restartTimer: Timer?
  private var generation = 0

  /// Spellings the recognizer commonly produces for "Jarvis".
  private let triggers = ["jarvis", "jervis", "javis", "jarvas", "jarvys", "jarviss", "charvis", "travis"]

  static func requestAuthorization() async -> Bool {
    if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  /// Call on the main thread.
  func start() throws {
    guard !isRunning else { return }
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw WakeError.notAuthorized }
    guard let recognizer, recognizer.isAvailable else { throw WakeError.recognizerUnavailable }
    isRunning = true
    lastHeard = ""
    beginRecognition()
  }

  /// Feed microphone audio (called on the audio thread).
  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    let current = request
    lock.unlock()
    current?.append(buffer)
  }

  /// Call on the main thread.
  func stop() {
    guard isRunning else { return }
    isRunning = false
    generation += 1
    restartTimer?.invalidate()
    restartTimer = nil
    lock.lock()
    request?.endAudio()
    request = nil
    lock.unlock()
    task?.cancel()
    task = nil
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
      if let text = result?.bestTranscription.formattedString.lowercased() {
        DispatchQueue.main.async { self.lastHeard = String(text.suffix(40)) }
        if self.triggers.contains(where: { text.contains($0) }) {
          DispatchQueue.main.async {
            guard self.isRunning, myGeneration == self.generation else { return }
            self.stop()
            self.onWake?()
          }
          return
        }
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
