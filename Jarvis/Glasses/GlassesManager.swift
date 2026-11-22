import Foundation
import MWDATCamera
import MWDATCore
import UIKit

/// Talks to the Ray-Ban Meta glasses through Meta's official Device Access Toolkit.
/// Nothing here touches the glasses' firmware: the toolkit only asks the Meta AI app for
/// camera frames, exactly like Meta's own sample apps do.
///
/// Battery/heat: the camera is only switched on when Jarvis needs to look, and it is
/// switched off again after `idleStreamSeconds` (unless "live camera" is enabled).
@MainActor
final class GlassesManager: ObservableObject {
  @Published private(set) var isRegistered = false
  @Published private(set) var isRegistering = false
  @Published private(set) var hasActiveDevice = false
  @Published private(set) var cameraPermissionGranted = false
  @Published private(set) var isStreaming = false
  @Published private(set) var lastError: String?

  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var session: DeviceSession?
  private var sessionState: DeviceSessionState = .idle
  private var camera: MWDATCamera.Camera?
  private var streamState: StreamState = .stopped
  private let sessionTokens = ListenerTokenBag()
  private let streamTokens = ListenerTokenBag()

  private var latestFrame: UIImage?
  private var latestFrameDate = Date.distantPast
  private var pendingPhoto: CheckedContinuation<UIImage?, Never>?
  private var autoStopTask: Task<Void, Never>?
  private var liveFrameHandler: ((UIImage) -> Void)?
  private var lastLiveFrameSent = Date.distantPast

  private let idleStreamSeconds: Double = 30

  init() {
    wearables = Wearables.shared
    deviceSelector = AutoDeviceSelector(wearables: wearables)
    isRegistered = wearables.registrationState == .registered

    Task { [weak self] in
      guard let self else { return }
      for await state in self.wearables.registrationStateStream() {
        self.isRegistered = state == .registered
        self.isRegistering = state == .registering
        if state == .registered { await self.refreshCameraPermission() }
      }
    }
    Task { [weak self] in
      guard let self else { return }
      for await deviceId in self.deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = deviceId != nil
      }
    }
    Task { await refreshCameraPermission() }
  }

  // MARK: - Registration (one-time link with the Meta AI app)

  func connect() {
    guard !isRegistering else { return }
    Task {
      do {
        try await wearables.startRegistration()
      } catch {
        lastError = "Σύνδεση με Meta AI απέτυχε: \(error.localizedDescription)"
      }
    }
  }

  func disconnect() {
    Task {
      stopSession()
      try? await wearables.startUnregistration()
    }
  }

  /// Meta AI calls the app back with a URL after registration / permission screens.
  func handleURL(_ url: URL) {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    else { return }
    Task {
      do {
        _ = try await wearables.handleUrl(url)
        await refreshCameraPermission()
      } catch {
        lastError = error.localizedDescription
      }
    }
  }

  // MARK: - Camera permission (granted inside the Meta AI app)

  func refreshCameraPermission() async {
    guard isRegistered else {
      cameraPermissionGranted = false
      return
    }
    let status = try? await wearables.checkPermissionStatus(.camera)
    cameraPermissionGranted = status == .granted
  }

  /// Opens the Meta AI app so the user can allow camera access. Only call from a button tap.
  func requestCameraPermission() {
    Task {
      do {
        let status = try await wearables.requestPermission(.camera)
        cameraPermissionGranted = status == .granted
      } catch {
        lastError = error.localizedDescription
      }
    }
  }

  // MARK: - Taking a picture

  /// Returns a fresh picture from the glasses, or nil (with `lastError` set).
  func captureImage() async -> UIImage? {
    lastError = nil
    guard isRegistered else {
      lastError = "Τα γυαλιά δεν έχουν συνδεθεί με την εφαρμογή (άνοιξε τον Jarvis και πάτα «Σύνδεση γυαλιών»)."
      return nil
    }
    await refreshCameraPermission()
    guard cameraPermissionGranted else {
      lastError = "Δεν έχει δοθεί άδεια κάμερας στο Meta AI (άνοιξε τον Jarvis και πάτα «Άδεια κάμερας»)."
      return nil
    }
    guard await ensureStream() else { return nil }
    scheduleAutoStop()

    // Prefer a real photo (sharper, better for reading text). Fall back to the latest video frame.
    if let photo = await capturePhotoWithTimeout(seconds: 6) {
      return photo
    }
    if let frame = latestFrame, Date().timeIntervalSince(latestFrameDate) < 3 {
      return frame
    }
    if lastError == nil { lastError = "Τα γυαλιά δεν έστειλαν εικόνα." }
    return nil
  }

  /// Live mode: calls `handler` with roughly one frame per second until `stopLiveFrames()`.
  func startLiveFrames(_ handler: @escaping (UIImage) -> Void) async -> Bool {
    liveFrameHandler = handler
    autoStopTask?.cancel()
    return await ensureStream()
  }

  func stopLiveFrames() {
    liveFrameHandler = nil
    scheduleAutoStop()
  }

  /// Fully releases the glasses (call when the conversation ends).
  func stopSession() {
    autoStopTask?.cancel()
    liveFrameHandler = nil
    stopStream()
    if let session {
      session.stop()
    }
    session = nil
    sessionTokens.clear()
    sessionState = .idle
  }

  // MARK: - Internals

  private func ensureSession() async -> Bool {
    if session != nil {
      if sessionState == .started { return true }
      if sessionState == .starting {
        return await waitFor(seconds: 12) { self.sessionState == .started }
      }
      // Paused / stopping / stopped: throw it away and make a fresh one.
      stopSession()
    }
    do {
      let newSession = try wearables.createSession(deviceSelector: deviceSelector)
      session = newSession
      newSession.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.handleSessionState(state) }
      }.store(in: sessionTokens)
      newSession.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.lastError = error.localizedDescription }
      }.store(in: sessionTokens)
      sessionState = .starting
      try newSession.start()
    } catch {
      lastError = "Δεν βρέθηκαν τα γυαλιά: \(error.localizedDescription)"
      session = nil
      sessionState = .idle
      return false
    }
    let ok = await waitFor(seconds: 12) { self.sessionState == .started }
    if !ok && lastError == nil {
      lastError = "Τα γυαλιά δεν απάντησαν. Φόρεσέ τα και βεβαιώσου ότι είναι συνδεδεμένα στο Meta AI."
    }
    return ok
  }

  private func handleSessionState(_ state: DeviceSessionState) {
    sessionState = state
    if state == .stopped {
      sessionTokens.clear()
      session = nil
      camera = nil
      streamTokens.clear()
      streamState = .stopped
      isStreaming = false
    }
  }

  private func ensureStream() async -> Bool {
    if camera != nil, streamState == .streaming { return true }
    guard await ensureSession(), let session else { return false }

    if camera == nil {
      // High resolution, low frame rate: sharper single frames (better for reading Greek text).
      let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 7)
      do {
        guard let newCamera = try session.addCamera(config: config) else {
          lastError = "Η κάμερα των γυαλιών δεν είναι διαθέσιμη."
          return false
        }
        camera = newCamera
        listen(to: newCamera.stream)
        streamState = .starting
        newCamera.stream.start()
      } catch {
        lastError = "Η κάμερα δεν ξεκίνησε: \(error.localizedDescription)"
        return false
      }
    }
    let ok = await waitFor(seconds: 10) { self.streamState == .streaming && self.latestFrame != nil }
    if !ok && lastError == nil {
      lastError = "Η κάμερα των γυαλιών δεν ξεκίνησε εγκαίρως."
    }
    return ok
  }

  private func listen(to stream: MWDATCamera.Stream) {
    latestFrame = nil
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        guard let self else { return }
        self.streamState = state
        self.isStreaming = state == .streaming
        if state == .stopped {
          self.streamTokens.clear()
          self.camera = nil
          self.latestFrame = nil
        }
      }
    }.store(in: streamTokens)

    stream.videoFramePublisher.listen { [weak self] frame in
      guard let image = frame.makeUIImage() else { return }
      Task { @MainActor in
        guard let self else { return }
        self.latestFrame = image
        self.latestFrameDate = Date()
        if let handler = self.liveFrameHandler, Date().timeIntervalSince(self.lastLiveFrameSent) >= 1 {
          self.lastLiveFrameSent = Date()
          handler(image)
        }
      }
    }.store(in: streamTokens)

    stream.photoDataPublisher.listen { [weak self] photo in
      let image = UIImage(data: photo.data)
      Task { @MainActor in
        guard let self else { return }
        self.pendingPhoto?.resume(returning: image)
        self.pendingPhoto = nil
      }
    }.store(in: streamTokens)

    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        self.lastError = error.localizedDescription
        self.pendingPhoto?.resume(returning: nil)
        self.pendingPhoto = nil
      }
    }.store(in: streamTokens)
  }

  private func capturePhotoWithTimeout(seconds: Double) async -> UIImage? {
    guard let camera, pendingPhoto == nil else { return nil }
    return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
      pendingPhoto = continuation
      if !camera.stream.capturePhoto(format: .jpeg) {
        pendingPhoto = nil
        continuation.resume(returning: nil)
        return
      }
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard let self, let pending = self.pendingPhoto else { return }
        self.pendingPhoto = nil
        pending.resume(returning: nil)
      }
    }
  }

  private func stopStream() {
    if let camera {
      camera.stop()
    }
    camera = nil
    streamTokens.clear()
    streamState = .stopped
    isStreaming = false
    latestFrame = nil
    pendingPhoto?.resume(returning: nil)
    pendingPhoto = nil
  }

  private func scheduleAutoStop() {
    autoStopTask?.cancel()
    guard liveFrameHandler == nil else { return }
    let delay = idleStreamSeconds
    autoStopTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self, !Task.isCancelled, self.liveFrameHandler == nil else { return }
      self.stopStream()
    }
  }

  private func waitFor(seconds: Double, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
  }
}
