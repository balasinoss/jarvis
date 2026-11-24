import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: Settings
  @EnvironmentObject private var app: AppModel
  @ObservedObject private var glasses = AppModel.shared.glasses
  @ObservedObject private var expiry = SideloadExpiry.shared
  @Environment(\.dismiss) private var dismiss

  private var theme: Theme { Theme(accent: settings.accent) }

  var body: some View {
    NavigationStack {
      ZStack {
        JarvisBackground(theme: theme)
        Form {
          languageSection
          voiceSection
          wakeSection
          cameraSection
          appearanceSection
          installSection
          keysSection
          claudeSection
          advancedSection
          glassesSection
        }
        .scrollContentBackground(.hidden)
        .tint(theme.primary)
      }
      .navigationTitle("Ρυθμίσεις")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Τέλος") { dismiss() }.bold() }
    }
    .preferredColorScheme(.dark)
  }

  private func row(_ title: String, _ icon: String) -> some View {
    Label {
      Text(title)
    } icon: {
      Image(systemName: icon).foregroundStyle(theme.gradient)
    }
  }

  // MARK: - Sections

  private var languageSection: some View {
    Section {
      Picker(selection: $settings.language) {
        ForEach(Settings.Language.allCases) { Text($0.label).tag($0) }
      } label: { row("Γλώσσα", "globe") }
      .pickerStyle(.segmented)

      Picker(selection: $settings.answerLength) {
        ForEach(Settings.AnswerLength.allCases) { Text($0.label).tag($0) }
      } label: { row("Μήκος απαντήσεων", "text.alignleft") }

      Picker(selection: $settings.tone) {
        ForEach(Settings.Tone.allCases) { Text($0.label).tag($0) }
      } label: { row("Ύφος", "face.smiling") }

      TextField("Πώς να σε λέει (προαιρετικό)", text: $settings.userName)

      VStack(alignment: .leading, spacing: 6) {
        row("Οδηγίες για τον Jarvis", "text.bubble")
        TextEditor(text: $settings.customInstructions)
          .frame(minHeight: 90)
          .scrollContentBackground(.hidden)
          .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
      }
    } header: {
      Text("Γλώσσα & απαντήσεις")
    } footer: {
      Text(
        "Ο Jarvis μιλάει μόνο τη γλώσσα που διαλέγεις, χωρίς αυτόματες αλλαγές. Π.χ. οδηγίες: «Σπουδάζω Μηχανολόγος Μηχανικός· εξήγα με παραδείγματα από μηχανική.» Οι αλλαγές ισχύουν από την επόμενη συνομιλία."
      )
    }
    .listRowBackground(Color.white.opacity(0.06))
  }

  private var voiceSection: some View {
    Section("Φωνή & ήχοι") {
      Picker(selection: $settings.geminiVoice) {
        ForEach(Settings.geminiVoices, id: \.self) { Text($0).tag($0) }
      } label: { row("Φωνή", "waveform") }
      Toggle(isOn: $settings.greetOnStart) { row("Λέει «Ναι;» όταν ξεκινά", "hand.wave") }
      Toggle(isOn: $settings.chime) { row("Ήχος «ντιν-ντιν»", "bell") }
      Toggle(isOn: $settings.haptics) { row("Δόνηση", "iphone.radiowaves.left.and.right") }
    }
    .listRowBackground(Color.white.opacity(0.06))
  }

  private var wakeSection: some View {
    Section {
      Toggle(isOn: Binding(get: { settings.wakeWord }, set: { app.setWakeWord($0) })) {
        row("Άκου για «Jarvis»", "ear")
      }
      Stepper(value: $settings.idleMinutes, in: 1...30) {
        row("Κλείνει μετά από \(settings.idleMinutes)′ σιωπής", "timer")
      }
      Toggle(isOn: $settings.halfDuplex) { row("Κλείσιμο μικροφώνου όσο μιλάει", "mic.slash") }
      Toggle(isOn: $settings.echoCancellation) { row("Ακύρωση ηχούς iPhone", "waveform.badge.minus") }
      Toggle(isOn: $settings.allowPhoneMic) { row("Μικρόφωνο κινητού αν χρειαστεί", "iphone") }
    } header: {
      Text("«Jarvis» & μικρόφωνο")
    } footer: {
      Text("Όσο περιμένει το «Jarvis», το μικρόφωνο των γυαλιών μένει ανοιχτό σαν κλήση: η μουσική ακούγεται πιο χαμηλής ποιότητας και η μπαταρία πέφτει πιο γρήγορα.")
    }
    .listRowBackground(Color.white.opacity(0.06))
  }

  private var cameraSection: some View {
    Section {
      LabeledContent {
        Text(glasses.cameraPermissionGranted ? "Δόθηκε ✓" : "Όχι")
          .foregroundStyle(glasses.cameraPermissionGranted ? Color.green : Color.orange)
      } label: { row("Άδεια κάμερας", "camera") }
      if glasses.isRegistered {
        Button(glasses.isRequestingPermission ? "Περιμένω το Meta AI…" : "Δώσε / ανανέωσε άδεια κάμερας") {
          glasses.requestCameraPermission()
        }
      }
      Picker(selection: $settings.cameraQuality) {
        ForEach(Settings.CameraQuality.allCases) { Text($0.label).tag($0) }
      } label: { row("Ποιότητα κάμερας", "camera.aperture") }
      Picker(selection: $settings.visionEngine) {
        ForEach(Settings.VisionEngine.allCases) { Text($0.label).tag($0) }
      } label: { row("Ανάγνωση εικόνας με", "eye") }
      Toggle(isOn: $settings.liveCamera) { row("Ζωντανή κάμερα (1 καρέ/δευτ.)", "video") }
      Button("Ενημέρωση γυαλιών για εφαρμογές (Meta)") { glasses.openGlassesAppUpdate() }
      Button("Ενημέρωση λογισμικού γυαλιών") { glasses.openFirmwareUpdate() }
    } header: {
      Text("Κάμερα γυαλιών")
    } footer: {
      Text("Η άδεια μένει αποθηκευμένη: ο Jarvis δεν τη ζητά ξανά, εκτός αν το Meta AI την ανακαλέσει. Στο Meta AI διάλεξε πάντα «Always allow».")
    }
    .listRowBackground(Color.white.opacity(0.06))
  }

  private var appearanceSection: some View {
    Section("Εμφάνιση") {
      Picker(selection: $settings.accent) {
        ForEach(Settings.Accent.allCases) { Text($0.label).tag($0) }
      } label: { row("Χρώματα", "paintpalette") }
      Toggle(isOn: $settings.showDiagnostics) { row("Γραμμή ελέγχου (για βλάβες)", "stethoscope") }
    }
    .listRowBackground(Color.white.opacity(0.06))
  }

  private var installSection: some View {
    Section {
      LabeledContent {
        Text(expiry.expiryDate == nil ? "—" : expiry.remainingText)
          .foregroundStyle(expiry.isSoon ? Color.orange : Color.white)
      } label: { row("Λήξη εφαρμογής", "calendar.badge.clock") }
      if expiry.expiryDate != nil {
        LabeledContent("Ημερομηνία", value: expiry.dateText)
      }
      Toggle(
        isOn: Binding(
          get: { settings.expiryReminders },
          set: {
            settings.expiryReminders = $0
            expiry.scheduleReminders(enabled: $0)
          })
      ) { row("Υπενθυμίσεις ανανέωσης", "bell.badge") }
    } header: {
      Text("Εγκατάσταση (7 ημέρες)")
    } footer: {
      Text(
        "Ειδοποίηση 2 μέρες, 1 μέρα και 3 ώρες πριν λήξει. Για αυτόματη ανανέωση: στο Sideloadly άφησε ενεργή την επιλογή αυτόματης ανανέωσης και το Sideloadly Daemon ανοιχτό στον υπολογιστή· ανανεώνει μόνο του όταν το iPhone είναι στο ίδιο Wi-Fi ή στο USB."
      )
    }
    .listRowBackground(Color.white.opacity(0.06))
  }

  private var keysSection: some View {
    Section {
      SecureField("Κλειδί Gemini (AIza…)", text: $settings.geminiKey)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
      Link("Πάρε δωρεάν κλειδί Gemini", destination: URL(string: "https://aistudio.google.com/apikey")!)
      SecureField("Κλειδί Claude (sk-ant-…) — προαιρετικό", text: $settings.claudeKey)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
      Link("Κλειδί Claude (πληρωμή ανά χρήση)", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
    } header: {
      Text("Κλειδιά")
    } footer: {
      Text("Αποθηκεύονται κρυπτογραφημένα στο Keychain του iPhone και στέλνονται μόνο στη Google και στην Anthropic.")
    }
    .listRowBackground(Color.white.opacity(0.06))
  }

  private var claudeSection: some View {
    Section("Claude") {
      TextField("Μοντέλο", text: $settings.claudeModel)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
      Toggle(isOn: $settings.claudeWebSearch) { row("Αναζήτηση στο web", "magnifyingglass") }
    }
    .listRowBackground(Color.white.opacity(0.06))
  }

  private var advancedSection: some View {
    Section {
      TextField("Μοντέλο Gemini Live", text: $settings.geminiModel)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
      Toggle(isOn: $settings.geminiSearch) { row("Google Search στο Gemini (με χρέωση)", "network") }
    } header: {
      Text("Για προχωρημένους")
    } footer: {
      Text("Αν η Google αλλάξει όνομα μοντέλου, γράψε εδώ το νέο.")
    }
    .listRowBackground(Color.white.opacity(0.06))
  }

  private var glassesSection: some View {
    Section("Γυαλιά") {
      LabeledContent("Συνδεδεμένα με Meta AI", value: glasses.isRegistered ? "Ναι" : "Όχι")
      LabeledContent("Βρέθηκαν τώρα", value: glasses.hasActiveDevice ? "Ναι" : "Όχι")
      if glasses.isRegistered {
        Button("Αποσύνδεση γυαλιών από τον Jarvis", role: .destructive) { glasses.disconnect() }
      } else {
        Button("Σύνδεση γυαλιών") { glasses.connect() }
      }
      Button("Καθαρισμός συνομιλίας") { app.clearTranscript() }
    }
    .listRowBackground(Color.white.opacity(0.06))
  }
}
