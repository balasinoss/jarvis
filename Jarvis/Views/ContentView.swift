import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var settings: Settings
  @ObservedObject private var glasses = AppModel.shared.glasses
  @State private var showSettings = false
  @State private var showNotes = false
  @State private var showPhoto = false
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        if needsSetup { SetupChecklist(showSettings: $showSettings) }
        statusHeader
        glassesAlert
        startButton
        wakeWordToggle
        transcriptView
      }
      .padding()
      .navigationTitle("Jarvis")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button { showNotes = true } label: { Image(systemName: "note.text") }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
      }
      .task { app.enterStandbyIfNeeded() }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          app.enterStandbyIfNeeded()
          Task { await glasses.refreshCameraPermission() }
        }
      }
      .onChange(of: settings.hasGeminiKey) { app.enterStandbyIfNeeded() }
      .sheet(isPresented: $showSettings) { SettingsView() }
      .sheet(isPresented: $showNotes) { NotesView() }
      .sheet(isPresented: $showPhoto) {
        if let photo = app.lastPhoto {
          Image(uiImage: photo).resizable().scaledToFit().padding()
        }
      }
    }
  }

  private var needsSetup: Bool {
    !settings.hasGeminiKey || !glasses.isRegistered || !glasses.cameraPermissionGranted
  }

  private var statusColor: Color {
    switch app.status {
    case .idle: return .gray
    case .standby: return .purple
    case .connecting, .working: return .orange
    case .listening: return .green
    case .speaking: return .blue
    case .error: return .red
    }
  }

  private var statusHeader: some View {
    HStack(spacing: 12) {
      Circle().fill(statusColor).frame(width: 14, height: 14)
      VStack(alignment: .leading, spacing: 2) {
        Text(app.status.label).font(.headline).lineLimit(3)
        if !app.micSource.isEmpty {
          Text(app.micSource).font(.caption).foregroundStyle(.secondary)
        }
        if !app.diagnostics.isEmpty {
          Text(app.diagnostics).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(4)
        }
      }
      Spacer()
      if let photo = app.lastPhoto {
        Button { showPhoto = true } label: {
          Image(uiImage: photo).resizable().scaledToFill()
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
    }
    .padding(12)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
  }

  /// Shows glasses problems (updates, camera errors) with a button to fix them.
  @ViewBuilder private var glassesAlert: some View {
    if glasses.needsGlassesAppUpdate || glasses.needsFirmwareUpdate || (glasses.lastError != nil && !needsSetup) {
      VStack(alignment: .leading, spacing: 8) {
        Label("Γυαλιά", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
        if let error = glasses.lastError {
          Text(error).font(.callout)
        }
        if glasses.needsGlassesAppUpdate {
          Button("Ενημέρωση γυαλιών για εφαρμογές") { glasses.openGlassesAppUpdate() }
            .buttonStyle(.borderedProminent)
        }
        if glasses.needsFirmwareUpdate {
          Button("Ενημέρωση λογισμικού γυαλιών") { glasses.openFirmwareUpdate() }
            .buttonStyle(.borderedProminent)
        }
        if !glasses.cameraPermissionGranted && glasses.isRegistered {
          Button("Άδεια κάμερας") { glasses.requestCameraPermission() }.buttonStyle(.bordered)
        }
        Button("Απόκρυψη") { glasses.clearError() }.font(.caption)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
  }

  private var startButton: some View {
    Button {
      app.toggle()
    } label: {
      Label(
        app.isActive ? "Σταμάτα" : "Μίλα στον Jarvis",
        systemImage: app.isActive ? "stop.fill" : "waveform"
      )
      .font(.title3.bold())
      .frame(maxWidth: .infinity)
      .padding(.vertical, 18)
    }
    .buttonStyle(.borderedProminent)
    .tint(app.isActive ? Color.red : Color.accentColor)
    .disabled(!app.isReadyToStart && !app.isActive)
  }

  private var wakeWordToggle: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(isOn: Binding(get: { settings.wakeWord }, set: { app.setWakeWord($0) })) {
        Label("Άκου για «Jarvis»", systemImage: "ear")
      }
      Text(
        settings.wakeWord
          ? "Πες «Jarvis» και μετά την ερώτησή σου. Όσο περιμένει, το μικρόφωνο των γυαλιών μένει ανοιχτό (σαν κλήση): η μουσική ακούγεται πιο χαμηλής ποιότητας και η μπαταρία πέφτει πιο γρήγορα."
          : "Κλειστό: ξεκινάς με το κουμπί, το Siri ή το Back Tap."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 4)
  }

  private var transcriptView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if app.transcript.isEmpty {
            Text(
              "Πες «Jarvis» (ή πάτα το κουμπί) και ρώτα π.χ.:\n• «Τι βλέπω;»\n• «Διάβασέ μου αυτή την πινακίδα»\n• «Λύσε μου την άσκηση στο βιβλίο»\n• «Στείλε στη Μαρία στο WhatsApp ότι αργώ 10 λεπτά»\n• «Σημείωσε να πάρω γάλα»"
            )
            .foregroundStyle(.secondary)
            .padding(.top, 8)
          }
          ForEach(app.transcript) { line in
            TranscriptRow(line: line).id(line.id)
          }
        }
      }
      .onChange(of: app.transcript.last?.text) {
        if let last = app.transcript.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
      }
    }
  }
}

struct TranscriptRow: View {
  let line: AppModel.Line

  var body: some View {
    switch line.role {
    case .user:
      HStack {
        Spacer(minLength: 40)
        Text(line.text).padding(10)
          .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
      }
    case .assistant:
      Text(line.text).padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    case .claude:
      VStack(alignment: .leading, spacing: 6) {
        Label("Claude", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.orange)
        Text(line.text).textSelection(.enabled)
      }
      .padding(10)
      .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    case .system:
      Text(line.text).font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct SetupChecklist: View {
  @EnvironmentObject private var settings: Settings
  @ObservedObject private var glasses = AppModel.shared.glasses
  @Binding var showSettings: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Ρύθμιση (μία φορά)").font(.headline)
      step(done: settings.hasGeminiKey, "1. Κλειδί Gemini", action: "Άνοιγμα") { showSettings = true }
      step(done: glasses.isRegistered, "2. Σύνδεση γυαλιών με Meta AI", action: glasses.isRegistering ? "…" : "Σύνδεση") {
        glasses.connect()
      }
      step(done: glasses.cameraPermissionGranted, "3. Άδεια κάμερας γυαλιών", action: "Άδεια") {
        glasses.requestCameraPermission()
      }
      .disabled(!glasses.isRegistered)
      if let error = glasses.lastError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      Text("Πρώτα: Meta AI → Ρυθμίσεις γυαλιών → Developer Mode = ON.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(12)
    .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
  }

  private func step(done: Bool, _ title: String, action: String, perform: @escaping () -> Void) -> some View {
    HStack {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(done ? .green : .secondary)
      Text(title)
      Spacer()
      if !done {
        Button(action, action: perform).buttonStyle(.bordered)
      }
    }
  }
}

struct NotesView: View {
  @ObservedObject private var store = NotesStore.shared
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if store.notes.isEmpty {
          Text("Πες «Jarvis, σημείωσε…» για να προσθέσεις σημείωση.").foregroundStyle(.secondary)
        }
        ForEach(store.notes) { note in
          VStack(alignment: .leading, spacing: 4) {
            Text(note.text)
            Text(note.date, style: .date).font(.caption).foregroundStyle(.secondary)
          }
        }
        .onDelete { store.delete(at: $0) }
      }
      .navigationTitle("Σημειώσεις")
      .toolbar { Button("Τέλος") { dismiss() } }
    }
  }
}
