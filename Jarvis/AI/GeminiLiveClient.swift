import Foundation

/// Minimal client for the Gemini Live API (real-time voice + vision over a WebSocket).
/// Runs entirely on the phone; no server or computer in between.
final class GeminiLiveClient: NSObject {
  struct ToolCall {
    let id: String
    let name: String
    let args: [String: Any]
  }

  enum Event {
    case ready
    case audio(Data)
    case interrupted
    case turnComplete
    case inputTranscript(String)
    case outputTranscript(String)
    case toolCall([ToolCall])
    case toolCallCancelled([String])
    case goingAway
    case resumptionHandle(String)
    case closed(String?)
  }

  struct Config {
    var apiKey: String
    var model: String
    var voice: String
    var systemPrompt: String
    var functionDeclarations: [[String: Any]]
    var googleSearch: Bool
    var resumptionHandle: String?
  }

  /// Delivered on the main thread.
  var onEvent: ((Event) -> Void)?

  private let config: Config
  private var urlSession: URLSession?
  private var task: URLSessionWebSocketTask?
  private var isReady = false
  private var closedReported = false
  private let sendQueue = DispatchQueue(label: "jarvis.gemini.send")
  private let bufferLock = NSLock()
  private var earlyAudio: [Data] = []

  init(config: Config) {
    self.config = config
  }

  // MARK: - Connection

  func connect() {
    var components = URLComponents(
      string:
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    )!
    components.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    let task = session.webSocketTask(with: components.url!)
    task.maximumMessageSize = 32 * 1024 * 1024
    urlSession = session
    self.task = task
    task.resume()
    sendSetup()
    receiveLoop()
  }

  func disconnect() {
    closedReported = true
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
  }

  // MARK: - Sending

  func sendAudio(_ pcm16k: Data) {
    guard isReady else {
      // Keep what you say while the connection is opening ("Jarvis… τι βλέπω;"),
      // and send it as soon as Gemini is ready. Max ~6 s.
      bufferLock.lock()
      earlyAudio.append(pcm16k)
      if earlyAudio.count > 60 { earlyAudio.removeFirst(earlyAudio.count - 60) }
      bufferLock.unlock()
      return
    }
    send([
      "realtimeInput": [
        "audio": ["data": pcm16k.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]
      ]
    ])
  }

  func sendImage(jpeg: Data) {
    guard isReady else { return }
    send([
      "realtimeInput": [
        "video": ["data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]
      ]
    ])
  }

  func sendText(_ text: String) {
    guard isReady else { return }
    send(["realtimeInput": ["text": text]])
  }

  func sendToolResponse(id: String, name: String, response: [String: Any]) {
    send([
      "toolResponse": [
        "functionResponses": [["id": id, "name": name, "response": response]]
      ]
    ])
  }

  private func sendSetup() {
    var setup: [String: Any] = [
      "model": config.model.hasPrefix("models/") ? config.model : "models/\(config.model)",
      "generationConfig": [
        "responseModalities": ["AUDIO"],
        "speechConfig": [
          "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": config.voice]]
        ],
      ],
      "systemInstruction": ["parts": [["text": config.systemPrompt]]],
      "inputAudioTranscription": [String: Any](),
      "outputAudioTranscription": [String: Any](),
      // Keeps long conversations going instead of hitting the session length limit.
      "contextWindowCompression": ["slidingWindow": [String: Any]()],
    ]
    var tools: [[String: Any]] = [["functionDeclarations": config.functionDeclarations]]
    if config.googleSearch { tools.append(["googleSearch": [String: Any]()]) }
    setup["tools"] = tools
    var resumption: [String: Any] = [:]
    if let handle = config.resumptionHandle { resumption["handle"] = handle }
    setup["sessionResumption"] = resumption
    send(["setup": setup], force: true)
  }

  private func send(_ object: [String: Any], force: Bool = false) {
    guard let task, force || isReady,
      let data = try? JSONSerialization.data(withJSONObject: object),
      let text = String(data: data, encoding: .utf8)
    else { return }
    sendQueue.async {
      task.send(.string(text)) { _ in }
    }
  }

  // MARK: - Receiving

  private func receiveLoop() {
    task?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.reportClosed(error.localizedDescription)
      case .success(let message):
        switch message {
        case .string(let text): self.handle(Data(text.utf8))
        case .data(let data): self.handle(data)
        @unknown default: break
        }
        self.receiveLoop()
      }
    }
  }

  private func handle(_ data: Data) {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

    if json["setupComplete"] != nil {
      isReady = true
      bufferLock.lock()
      let early = earlyAudio
      earlyAudio.removeAll()
      bufferLock.unlock()
      for chunk in early { sendAudio(chunk) }
      emit(.ready)
    }

    if let content = json["serverContent"] as? [String: Any] {
      if let turn = content["modelTurn"] as? [String: Any],
        let parts = turn["parts"] as? [[String: Any]]
      {
        for part in parts {
          if let inline = part["inlineData"] as? [String: Any],
            let b64 = inline["data"] as? String,
            let audio = Data(base64Encoded: b64)
          {
            emit(.audio(audio))
          }
        }
      }
      if let t = (content["inputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty {
        emit(.inputTranscript(t))
      }
      if let t = (content["outputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty {
        emit(.outputTranscript(t))
      }
      if content["interrupted"] as? Bool == true { emit(.interrupted) }
      if content["turnComplete"] as? Bool == true { emit(.turnComplete) }
    }

    if let toolCall = json["toolCall"] as? [String: Any],
      let calls = toolCall["functionCalls"] as? [[String: Any]]
    {
      let parsed = calls.compactMap { call -> ToolCall? in
        guard let name = call["name"] as? String else { return nil }
        return ToolCall(
          id: call["id"] as? String ?? UUID().uuidString,
          name: name,
          args: call["args"] as? [String: Any] ?? [:])
      }
      if !parsed.isEmpty { emit(.toolCall(parsed)) }
    }

    if let cancel = json["toolCallCancellation"] as? [String: Any], let ids = cancel["ids"] as? [String] {
      emit(.toolCallCancelled(ids))
    }

    if let update = json["sessionResumptionUpdate"] as? [String: Any],
      update["resumable"] as? Bool != false,
      let handle = update["newHandle"] as? String, !handle.isEmpty
    {
      emit(.resumptionHandle(handle))
    }

    if json["goAway"] != nil { emit(.goingAway) }

    if let error = json["error"] as? [String: Any] {
      reportClosed(error["message"] as? String ?? "Σφάλμα Gemini")
    }
  }

  private func reportClosed(_ reason: String?) {
    guard !closedReported else { return }
    closedReported = true
    isReady = false
    emit(.closed(reason))
  }

  private func emit(_ event: Event) {
    DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
  }
}

extension GeminiLiveClient: URLSessionWebSocketDelegate {
  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let text = reason.flatMap { String(data: $0, encoding: .utf8) }
    reportClosed(text?.isEmpty == false ? text : "Η σύνδεση με το Gemini έκλεισε (\(closeCode.rawValue)).")
  }
}
