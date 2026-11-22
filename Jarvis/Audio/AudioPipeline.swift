import AVFoundation
import Foundation

/// Microphone in (glasses mic over Bluetooth, 16 kHz PCM for Gemini) and voice out
/// (Gemini's 24 kHz PCM played through the glasses speakers).
///
/// Bluetooth headsets often renegotiate the connection when playback starts, which silently
/// stops AVAudioEngine's microphone. A watchdog notices when no mic audio arrives for a
/// moment and rebuilds the engine, so Jarvis keeps hearing you.
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
  /// Called on the audio thread with the raw mic buffer (used by the "Jarvis" wake word).
  var onRawMicBuffer: ((AVAudioPCMBuffer) -> Void)?
  /// Called on the main thread when Jarvis starts/stops talking.
  var onSpeakingChanged: ((Bool) -> Void)?

  private(set) var usingGlassesMic = false

  // Diagnostics shown on screen.
  private(set) var tapBuffers = 0
  private(set) var chunksOut = 0
  private(set) var micLevel: Float = 0  // 0…1
  private(set) var restarts = 0

  private var engine = AVAudioEngine()
  private var player = AVAudioPlayerNode()
  private let playbackFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
  private let sendFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
  private var converter: AVAudioConverter?
  private var micBuffer = Data()
  private let lock = NSLock()
  private var scheduledBuffers = 0
  private var running = false
  private var echoCancellation = false
  private var allowPhoneMic = true
  private var lastTapDate = Date()
  private var lastRebuild = Date.distantPast
  private var watchdog: Timer?
  private var sessionObservers: [NSObjectProtocol] = []
  private var engineObserver: NSObjectProtocol?

  var isRunning: Bool { running }

  var isSpeaking: Bool {
    lock.lock()
    defer { lock.unlock() }
    return scheduledBuffers > 0
  }

  // MARK: - Start / stop (call on the main thread)

  func start(allowPhoneMic: Bool, echoCancellation: Bool = false) throws {
    guard !running else { return }
    self.allowPhoneMic = allowPhoneMic
    self.echoCancellation = echoCancellation
    tapBuffers = 0
    chunksOut = 0
    micLevel = 0
    restarts = 0

    try configureSession()
    do {
      try buildEngine()
    } catch {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      throw error
    }
    running = true
    lastTapDate = Date()
    observeSession()
    startWatchdog()
  }

  /// `deactivateSession: false` is used when going back to "Jarvis" standby, so the
  /// audio session stays alive in the background.
  func stop(deactivateSession: Bool = true) {
    guard running else { return }
    running = false
    watchdog?.invalidate()
    watchdog = nil
    sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    sessionObservers.removeAll()
    tearDownEngine()
    lock.lock()
    scheduledBuffers = 0
    micBuffer.removeAll()
    lock.unlock()
    if deactivateSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    DispatchQueue.main.async { self.onSpeakingChanged?(false) }
  }

  // MARK: - Engine lifecycle

  private func configureSession() throws {
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
  }

  /// Creates a fresh engine + player, installs the mic tap and starts everything.
  private func buildEngine() throws {
    let newEngine = AVAudioEngine()
    let newPlayer = AVAudioPlayerNode()
    try? newEngine.inputNode.setVoiceProcessingEnabled(echoCancellation)
    newEngine.attach(newPlayer)
    newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: playbackFormat)

    // Right after a Bluetooth route change the input format can briefly be 0 Hz. Wait for it.
    var inFormat = newEngine.inputNode.outputFormat(forBus: 0)
    var attempts = 0
    while (inFormat.sampleRate <= 0 || inFormat.channelCount == 0) && attempts < 15 {
      Thread.sleep(forTimeInterval: 0.1)
      inFormat = newEngine.inputNode.outputFormat(forBus: 0)
      attempts += 1
    }
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw AudioError.noMicrophone }

    converter = AVAudioConverter(from: inFormat, to: sendFormat)
    newEngine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
      self?.handleMic(buffer)
    }
    newEngine.prepare()
    try newEngine.start()
    newPlayer.play()

    engine = newEngine
    player = newPlayer
    if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
    engineObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
    ) { [weak self] _ in
      self?.rebuild(reason: "config")
    }
  }

  private func tearDownEngine() {
    if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
    engineObserver = nil
    engine.inputNode.removeTap(onBus: 0)
    player.stop()
    engine.stop()
  }

  /// Throws the current engine away and starts a new one (keeps the conversation going).
  private func rebuild(reason: String) {
    guard running else { return }
    // Don't thrash: at most one rebuild per second.
    guard Date().timeIntervalSince(lastRebuild) > 1 else { return }
    lastRebuild = Date()
    restarts += 1
    tearDownEngine()
    lock.lock()
    scheduledBuffers = 0
    micBuffer.removeAll()
    lock.unlock()
    DispatchQueue.main.async { self.onSpeakingChanged?(false) }
    do {
      let session = AVAudioSession.sharedInstance()
      try? session.setActive(true)
      if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
        try? session.setPreferredInput(glasses)
      }
      usingGlassesMic = session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
      try buildEngine()
    } catch {
      // Try again on the next watchdog tick.
    }
    lastTapDate = Date()
  }

  private func startWatchdog() {
    watchdog?.invalidate()
    watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self, self.running else { return }
      if Date().timeIntervalSince(self.lastTapDate) > 1.2 {
        self.rebuild(reason: "watchdog")
      }
    }
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

    let currentPlayer = player
    currentPlayer.scheduleBuffer(buffer) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
      let nowSilent = self.scheduledBuffers == 0
      self.lock.unlock()
      if nowSilent { DispatchQueue.main.async { self.onSpeakingChanged?(false) } }
    }
    if engine.isRunning && !currentPlayer.isPlaying { currentPlayer.play() }
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
        let envelope = Float(sin(Double.pi * Double(local) / Double(toneFrames)))
        value = Float(sin(2 * Double.pi * frequency * Double(local) / rate)) * 0.25 * envelope
      }
      out[i] = value
    }
    player.scheduleBuffer(buffer, completionHandler: nil)
    if engine.isRunning && !player.isPlaying { player.play() }
  }

  /// Drops anything still queued (used when the user interrupts Jarvis).
  func flushPlayback() {
    guard running else { return }
    player.stop()
    lock.lock()
    scheduledBuffers = 0
    lock.unlock()
    if engine.isRunning { player.play() }
    DispatchQueue.main.async { self.onSpeakingChanged?(false) }
  }

  // MARK: - Microphone

  private func handleMic(_ buffer: AVAudioPCMBuffer) {
    tapBuffers += 1
    lastTapDate = Date()
    onRawMicBuffer?(buffer)
    guard let converter, buffer.format.sampleRate > 0 else { return }
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
    var peak: Int32 = 0
    for i in 0..<Int(out.frameLength) { peak = max(peak, abs(Int32(samples[i]))) }
    micLevel = Float(peak) / 32768

    lock.lock()
    micBuffer.append(bytes)
    var chunks: [Data] = []
    while micBuffer.count >= 3200 {  // 100 ms at 16 kHz * 2 bytes
      chunks.append(micBuffer.prefix(3200))
      micBuffer.removeFirst(3200)
    }
    lock.unlock()
    chunksOut += chunks.count
    for chunk in chunks { onMicChunk?(Data(chunk)) }
  }

  // MARK: - Interruptions (phone calls, Siri, Meta AI)

  private func observeSession() {
    let center = NotificationCenter.default
    sessionObservers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let self, self.running,
          let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .ended
        else { return }
        self.lastRebuild = .distantPast
        self.rebuild(reason: "interruption")
      })
    sessionObservers.append(
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.lastRebuild = .distantPast
        self?.rebuild(reason: "reset")
      })
  }
}
