import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var settings: Settings
  @ObservedObject private var glasses = AppModel.shared.glasses
  @ObservedObject private var expiry = SideloadExpiry.shared
  @State private var showSettings = false
  @State private var showNotes = false
  @State private var showPhoto = false
  @Environment(\.scenePhase) private var scenePhase

  private var theme: Theme { Theme(accent: settings.accent) }

  var body: some View {
    ZStack {
      JarvisBackground(theme: theme)

      VStack(spacing: 14) {
        header
        ScrollViewReader { proxy in
          ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
              if needsSetup { SetupChecklist(theme: theme, showSettings: $showSettings) }
              glassesAlert
              if expiry.isSoon { expiryBanner }

              OrbButton(theme: theme, status: app.status, isActive: app.isActive, level: app.micLevel) {
                app.toggle()
              }
              .disabled(!app.isReadyToStart && !app.isActive)
              .padding(.top, 6)

              statusText
              wakeWordToggle

              LazyVStack(alignment: .leading, spacing: 10) {
                if app.transcript.isEmpty { examples }
                ForEach(app.transcript) { line in
                  TranscriptRow(line: line, theme: theme).id(line.id)
                }
              }
              .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
          }
          .onChange(of: app.transcript.last?.text) {
            if let last = app.transcript.last {
              withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
          }
        }
      }
    }
    .preferredColorScheme(.dark)
    .task {
      app.enterStandbyIfNeeded()
      expiry.scheduleReminders(enabled: settings.expiryReminders)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        app.enterStandbyIfNeeded()
        Task { await glasses.refreshCameraPermission() }
      }
    }
    .onChange(of: settings.hasGeminiKey) { app.enterStandbyIfNeeded() }
    .sheet(isPresented: $showSettings) { SettingsView() }
    .sheet(isPresented: $showNotes) { NotesView(theme: theme) }
    .sheet(isPresented: $showPhoto) {
      ZStack {
        JarvisBackground(theme: theme)
        if let photo = app.lastPhoto {
          Image(uiImage: photo).resizable().scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding()
        }
      }
      .preferredColorScheme(.dark)
    }
  }

  private var needsSetup: Bool {
    !settings.hasGeminiKey || !glasses.isRegistered || !glasses.cameraPermissionGranted
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      GlassIconButton(systemName: "note.text") { showNotes = true }
      Spacer()
      VStack(spacing: 0) {
        Text("Jarvis")
          .font(.system(size: 30, weight: .bold, design: .rounded))
          .foregroundStyle(theme.gradient)
        if !app.micSource.isEmpty {
          Text(app.micSource).font(.caption2).foregroundStyle(.white.opacity(0.55))
        }
      }
      Spacer()
      if let photo = app.lastPhoto {
        Button { showPhoto = true } label: {
          Image(uiImage: photo).resizable().scaledToFill()
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
      }
      GlassIconButton(systemName: "gearshape.fill") { showSettings = true }
    }
    .padding(.horizontal, 16)
    .padding(.top, 6)
  }

  // MARK: - Status

  private var statusText: some View {
    VStack(spacing: 4) {
      Text(app.status.label)
        .font(.headline)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .lineLimit(3)
      if !app.diagnostics.isEmpty {
        Text(app.diagnostics)
          .font(.caption2.monospaced())
          .foregroundStyle(.white.opacity(0.5))
          .multilineTextAlignment(.center)
          .lineLimit(4)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var wakeWordToggle: some View {
    Toggle(isOn: Binding(get: { settings.wakeWord }, set: { app.setWakeWord($0) })) {
      HStack(spacing: 10) {
        Image(systemName: "ear.fill").foregroundStyle(theme.gradient)
        VStack(alignment: .leading, spacing: 2) {
          Text("Άκου για «Jarvis»").font(.subheadline.weight(.semibold))
          Text(settings.wakeWord ? "Πες «Jarvis» και την ερώτησή σου" : "Ξεκινάς με το κουμπί ή το Siri")
            .font(.caption).foregroundStyle(.white.opacity(0.6))
        }
      }
    }
    .tint(theme.primary)
    .glassCard(cornerRadius: 20)
  }

  private var examples: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Δοκίμασε να πεις").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
      ForEach(
        [
          "«Jarvis, τι βλέπω;»", "«Διάβασέ μου τι γράφει εδώ»", "«Λύσε μου την άσκηση στο βιβλίο»",
          "«Εξήγησέ μου αναλυτικά τον δεύτερο νόμο του Νεύτωνα»", "«Σημείωσε να πάρω ψωμί»",
        ], id: \.self
      ) { example in
        Text(example).font(.subheadline).foregroundStyle(.white.opacity(0.85))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassCard()
  }

  // MARK: - Banners

  private var expiryBanner: some View {
    HStack(spacing: 12) {
      Image(systemName: "clock.badge.exclamationmark.fill").font(.title2).foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("Η εφαρμογή λήγει \(expiry.remainingText)").font(.subheadline.weight(.semibold))
        Text("Ανανέωσέ τη με το Sideloadly (ίδιο αρχείο, πάτα Start).")
          .font(.caption).foregroundStyle(.white.opacity(0.7))
      }
      Spacer()
    }
    .glassCard(tint: .orange)
  }

  /// Glasses problems (updates, camera errors) with a button to fix them.
  @ViewBuilder private var glassesAlert: some View {
    if glasses.needsGlassesAppUpdate || glasses.needsFirmwareUpdate || (glasses.lastError != nil && !needsSetup) {
      VStack(alignment: .leading, spacing: 10) {
        Label("Γυαλιά", systemImage: "eyeglasses").font(.headline).foregroundStyle(.orange)
        if let error = glasses.lastError {
          Text(error).font(.callout).foregroundStyle(.white.opacity(0.9))
        }
        HStack {
          if glasses.needsGlassesAppUpdate {
            Button("Ενημέρωση για εφαρμογές") { glasses.openGlassesAppUpdate() }
              .buttonStyle(.borderedProminent).tint(.orange)
          }
          if glasses.needsFirmwareUpdate {
            Button("Ενημέρωση γυαλιών") { glasses.openFirmwareUpdate() }
              .buttonStyle(.borderedProminent).tint(.orange)
          }
          if !glasses.cameraPermissionGranted && glasses.isRegistered {
            Button(glasses.isRequestingPermission ? "Περιμένω το Meta AI…" : "Άδεια κάμερας") {
              glasses.requestCameraPermission()
            }
            .buttonStyle(.bordered)
          }
          Spacer()
          Button { glasses.clearError() } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassCard(tint: .orange)
    }
  }
}

// MARK: - The orb (start / stop)

struct OrbButton: View {
  let theme: Theme
  let status: AppModel.Status
  let isActive: Bool
  let level: Double
  let action: () -> Void

  private var stateColors: [Color] {
    switch status {
    case .error: return [.red, .orange, .red]
    case .standby: return [theme.colors[1], theme.colors[0], theme.colors[1]]
    case .idle: return [theme.colors[0].opacity(0.7), theme.colors[1].opacity(0.7), theme.colors[0].opacity(0.7)]
    default: return theme.colors + [theme.colors[0]]
    }
  }

  var body: some View {
    Button(action: action) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        let speaking = status == .speaking
        let breathing = isActive ? (speaking ? 0.06 : 0.03) * sin(t * (speaking ? 6 : 2.2)) : 0
        let scale = 1 + breathing + (isActive ? level * 0.18 : 0)

        ZStack {
          // Glow
          Circle()
            .fill(AngularGradient(colors: stateColors, center: .center, angle: .degrees(t * 40)))
            .frame(width: 190, height: 190)
            .blur(radius: 40)
            .opacity(isActive ? 0.9 : 0.5)
            .scaleEffect(scale * 1.05)

          // Glass sphere
          Circle()
            .fill(AngularGradient(colors: stateColors, center: .center, angle: .degrees(-t * 30)))
            .frame(width: 170, height: 170)
            .overlay(
              Circle().fill(.ultraThinMaterial).opacity(0.35)
            )
            .overlay(
              // Specular highlight
              Circle()
                .fill(
                  RadialGradient(
                    colors: [.white.opacity(0.75), .white.opacity(0.0)], center: UnitPoint(x: 0.32, y: 0.25),
                    startRadius: 2, endRadius: 80))
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1.2))
            .shadow(color: theme.primary.opacity(0.6), radius: 25)
            .scaleEffect(scale)

          Image(systemName: isActive ? "stop.fill" : "waveform")
            .font(.system(size: 42, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 6)
            .symbolEffect(.variableColor.iterative, isActive: status == .speaking || status == .listening)
        }
        .frame(width: 230, height: 230)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isActive ? "Σταμάτα" : "Μίλα στον Jarvis")
  }
}

// MARK: - Transcript

struct TranscriptRow: View {
  let line: AppModel.Line
  let theme: Theme

  var body: some View {
    switch line.role {
    case .user:
      HStack {
        Spacer(minLength: 48)
        Text(line.text)
          .foregroundStyle(.white)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.gradient).opacity(0.85))
          .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
      }
    case .assistant:
      HStack {
        Text(line.text)
          .foregroundStyle(.white)
          .textSelection(.enabled)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
        Spacer(minLength: 32)
      }
    case .claude:
      VStack(alignment: .leading, spacing: 6) {
        Label("Claude", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.orange)
        Text(line.text).foregroundStyle(.white).textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassCard(cornerRadius: 20, tint: .orange)
    case .system:
      Text(line.text)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity, alignment: .center)
    }
  }
}

// MARK: - First-time setup

struct SetupChecklist: View {
  let theme: Theme
  @EnvironmentObject private var settings: Settings
  @ObservedObject private var glasses = AppModel.shared.glasses
  @Binding var showSettings: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Ρύθμιση (μία φορά)").font(.headline)
      step(done: settings.hasGeminiKey, "Κλειδί Gemini", action: "Άνοιγμα") { showSettings = true }
      step(done: glasses.isRegistered, "Σύνδεση γυαλιών με Meta AI", action: glasses.isRegistering ? "…" : "Σύνδεση") {
        glasses.connect()
      }
      step(
        done: glasses.cameraPermissionGranted, "Άδεια κάμερας γυαλιών",
        action: glasses.isRequestingPermission ? "…" : "Άδεια"
      ) {
        glasses.requestCameraPermission()
      }
      .disabled(!glasses.isRegistered)
      if let error = glasses.lastError {
        Text(error).font(.caption).foregroundStyle(.orange)
      }
      Text("Πρώτα: Meta AI → Settings → App Info → πάτα 5 φορές την έκδοση → Developer Mode.")
        .font(.caption).foregroundStyle(.white.opacity(0.6))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassCard(tint: theme.primary)
  }

  private func step(done: Bool, _ title: String, action: String, perform: @escaping () -> Void) -> some View {
    HStack {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(done ? Color.green : Color.white.opacity(0.5))
      Text(title)
      Spacer()
      if !done {
        Button(action, action: perform).buttonStyle(.borderedProminent).tint(theme.primary)
      }
    }
  }
}

// MARK: - Notes

struct NotesView: View {
  let theme: Theme
  @ObservedObject private var store = NotesStore.shared
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        JarvisBackground(theme: theme)
        List {
          if store.notes.isEmpty {
            Text("Πες «Jarvis, σημείωσε…» για να προσθέσεις σημείωση.").foregroundStyle(.white.opacity(0.6))
              .listRowBackground(Color.clear)
          }
          ForEach(store.notes) { note in
            VStack(alignment: .leading, spacing: 4) {
              Text(note.text)
              Text(note.date, style: .date).font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            .listRowBackground(Color.white.opacity(0.06))
          }
          .onDelete { store.delete(at: $0) }
        }
        .scrollContentBackground(.hidden)
      }
      .navigationTitle("Σημειώσεις")
      .toolbar { Button("Τέλος") { dismiss() } }
    }
    .preferredColorScheme(.dark)
  }
}
