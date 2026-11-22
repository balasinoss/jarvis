import AVFoundation
import Foundation

/// Microphone in (glasses mic over Bluetooth, 16 kHz PCM for Gemini) and voice out
/// (Gemini's 24 kHz PCM played through the glasses speakers).
///
/// The audio session is only active while a conversation is running. When it ends we
/// deactivate it, so music, calls and "Hey Meta" on the glasses work exactly as before.
final class AudioPipeline {
  enum AudioError: LocalizedError {
    case noMicrophone
    case glassesMicMissing
    var errorDescription: String? {
      switch self {
      case .noMicrophone: return "Δεν βρέθηκε μικρόφωνο."
      case .glassesMicMissing: return "Τα γυαλιά δεν είναι συνδεδεμένα με Bluetooth στο κινητό."
      }
    }
  }

  /// Called on an audio thread with ~100 ms of 16-bit/16 kHz mono PCM.
  var onMicChunk: ((Data) -> Void)?
  /// Called on the main thread when Jarvis starts/stops talking.
  var onSpeakingChanged: ((Bool) -> Void)?

  private(set) var usingGlassesMic = false

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let playbackFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
  private let sendFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
  private var converter: AVAudioConverter?
  private var micBuffer = Data()
  private let lock = NSLock()
  private var scheduledBuffers = 0
  private var running = false
  private var observers: [NSObjectProtocol] = []

  var isSpeaking: Bool {
    lock.lock()
    defer { lock.unlock() }
    return scheduledBuffers > 0
  }

  // MARK: - Start / stop

  func start(allowPhoneMic: Bool) throws {
    guard !running else { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
    try session.setActive(true)

    if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
      try? session.setPreferredInput(glasses)
    }
    usingGlassesMic = session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    if !usingGlassesMic && !allowPhoneMic {
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw AudioError.glassesMicMissing
    }

    // Echo cancellation, so Jarvis doesn't hear (and interrupt) himself.
    try? engine.inputNode.setVoiceProcessingEnabled(true)

    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

    guard installMicTap() else {
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw AudioError.noMicrophone
    }

    engine.prepare()
    try engine.start()
    player.play()
    running = true
    observeInterruptions()
  }

  /// `deactivateSession: false` is used when going back to "Jarvis" standby, so the
  /// audio session stays alive in the background.
  func stop(deactivateSession: Bool = true) {
    guard running else { return }
    running = false
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    engine.inputNode.removeTap(onBus: 0)
    player.stop()
    engine.stop()
    engine.detach(player)
    lock.lock()
    scheduledBuffers = 0
    micBuffer.removeAll()
    lock.unlock()
    // Hand the audio back to the system (music, calls, Meta AI).
    if deactivateSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    DispatchQueue.main.async { self.onSpeakingChanged?(false) }
  }

  // MARK: - Playback

  /// Plays 16-bit little-endian mono PCM at 24 kHz (what Gemini Live sends back).
  func play(pcm24k data: Data) {
    guard running, data.count >= 2 else { return }
    let frames = data.count / 2
    guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)),
      let out = buffer.floatChannelData?[0]
    else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      for i in 0..<frames {
        let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
        out[i] = Float(sample) / 32768.0
      }
    }
    lock.lock()
    let wasSilent = scheduledBuffers == 0
    scheduledBuffers += 1
    lock.unlock()
    if wasSilent { DispatchQueue.main.async { self.onSpeakingChanged?(true) } }

    player.scheduleBuffer(buffer) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
      let nowSilent = self.scheduledBuffers == 0
      self.lock.unlock()
      if nowSilent { DispatchQueue.main.async { self.onSpeakingChanged?(false) } }
    }
    if !player.isPlaying { player.play() }
  }

  /// Short rising "ding-ding" so you know Jarvis is listening.
  func playChime() {
    guard running else { return }
    let rate = playbackFormat.sampleRate
    let toneFrames = Int(rate * 0.11)
    let gapFrames = Int(rate * 0.03)
    let total = toneFrames * 2 + gapFrames
    guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(total)),
      let out = buffer.floatChannelData?[0]
    else { return }
    buffer.frameLength = AVAudioFrameCount(total)
    for i in 0..<total {
      var value: Float = 0
      if i < toneFrames || i >= toneFrames + gapFrames {
        let local = i < toneFrames ? i : i - toneFrames - gapFrames
        let frequency: Double = i < toneFrames ? 880 : 1320
        let envelope = Float(sin(Double.pi * Double(local) / Double(toneFrames)))  // soft fade in/out
        value = Float(sin(2 * Double.pi * frequency * Double(local) / rate)) * 0.25 * envelope
      }
      out[i] = value
    }
    player.scheduleBuffer(buffer, completionHandler: nil)
    if !player.isPlaying { player.play() }
  }

  /// Drops anything still queued (used when the user interrupts Jarvis).
  func flushPlayback() {
    guard running else { return }
    player.stop()
    lock.lock()
    scheduledBuffers = 0
    lock.unlock()
    player.play()
    DispatchQueue.main.async { self.onSpeakingChanged?(false) }
  }

  // MARK: - Microphone

  @discardableResult
  private func installMicTap() -> Bool {
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    let inFormat = input.outputFormat(forBus: 0)
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { return false }
    converter = AVAudioConverter(from: inFormat, to: sendFormat)
    input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
      self?.handleMic(buffer)
    }
    return true
  }

  private func handleMic(_ buffer: AVAudioPCMBuffer) {
    guard let converter else { return }
    let ratio = sendFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return }

    var supplied = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
    let bytes = Data(bytes: samples, count: Int(out.frameLength) * 2)

    lock.lock()
    micBuffer.append(bytes)
    var chunks: [Data] = []
    while micBuffer.count >= 3200 {  // 100 ms at 16 kHz * 2 bytes
      chunks.append(micBuffer.prefix(3200))
      micBuffer.removeFirst(3200)
    }
    lock.unlock()
    for chunk in chunks { onMicChunk?(Data(chunk)) }
  }

  // MARK: - Interruptions (phone calls, Siri, Meta AI)

  private func observeInterruptions() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let self, self.running,
          let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        if type == .ended {
          try? AVAudioSession.sharedInstance().setActive(true)
          if !self.engine.isRunning { try? self.engine.start() }
          self.player.play()
        }
      })
    observers.append(
      center.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
      ) { [weak self] _ in
        // Route changed (e.g. glasses reconnected): rebuild the mic tap for the new format.
        guard let self, self.running else { return }
        self.engine.stop()
        self.installMicTap()
        self.engine.prepare()
        try? self.engine.start()
        self.player.play()
      })
  }
}
