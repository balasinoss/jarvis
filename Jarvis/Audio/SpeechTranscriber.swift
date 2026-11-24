import AVFoundation
import Foundation
import Speech

/// Writes what YOU say on screen, in the language you picked (Greek or English).
///
/// Gemini Live's own transcription guesses the language on its own and often produces
/// scrambled text in random languages (a known Gemini issue), even though Gemini understood
/// you fine. So the on-screen text comes from the iPhone's speech recognizer instead.
/// It only affects what you see; Gemini still hears your voice directly.
final class SpeechTranscriber {
  /// (text so far, utterance number). Called on the main thread.
  var onText: ((String, Int) -> Void)?

  private(set) var isRunning = false
  private var recognizer: SFSpeechRecognizer?
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var restartTimer: Timer?
  private var generation = 0

  /// Call on the main thread.
  func start(localeIdentifier: String) {
    guard !isRunning, SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
    recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    guard let recognizer, recognizer.isAvailable else { return }
    isRunning = true
    begin()
  }

  /// Feed microphone audio (audio thread).
  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    let current = request
    lock.unlock()
    current?.append(buffer)
  }

  /// Jarvis started answering: whatever you say next goes on a new line.
  func nextUtterance() {
    guard isRunning else { return }
    begin()
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

  private func begin() {
    guard isRunning, let recognizer else { return }
    generation += 1
    let myGeneration = generation
    task?.cancel()

    let newRequest = SFSpeechAudioBufferRecognitionRequest()
    newRequest.shouldReportPartialResults = true
    newRequest.taskHint = .dictation
    newRequest.addsPunctuation = true
    if recognizer.supportsOnDeviceRecognition {
      newRequest.requiresOnDeviceRecognition = true
    }
    lock.lock()
    request?.endAudio()
    request = newRequest
    lock.unlock()

    task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
      guard let self else { return }
      if let text = result?.bestTranscription.formattedString, !text.isEmpty {
        DispatchQueue.main.async {
          guard self.isRunning, myGeneration == self.generation else { return }
          self.onText?(text, myGeneration)
        }
      }
      if error != nil || result?.isFinal == true {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          guard self.isRunning, myGeneration == self.generation else { return }
          self.begin()
        }
      }
    }

    // Apple limits one recognition to about a minute; start fresh well before that.
    restartTimer?.invalidate()
    restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
      guard let self, self.isRunning, myGeneration == self.generation else { return }
      self.begin()
    }
  }
}
