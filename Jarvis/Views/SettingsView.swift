import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: Settings
  @EnvironmentObject private var app: AppModel
  @ObservedObject private var glasses = AppModel.shared.glasses
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
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
          Text("Τα κλειδιά αποθηκεύονται κρυπτογραφημένα στο Keychain του iPhone και στέλνονται μόνο στη Google και στην Anthropic.")
        }

        Section("Φωνή & γλώσσα") {
          Picker("Γλώσσα", selection: $settings.language) {
            ForEach(Settings.Language.allCases) { Text($0.label).tag($0) }
          }
          Picker("Φωνή", selection: $settings.geminiVoice) {
            ForEach(Settings.geminiVoices, id: \.self) { Text($0).tag($0) }
          }
          Toggle("Κλείσιμο μικροφώνου όσο μιλάει", isOn: $settings.halfDuplex)
          Toggle("Μικρόφωνο κινητού αν λείπουν τα γυαλιά", isOn: $settings.allowPhoneMic)
          Stepper("Αυτόματο κλείσιμο μετά από \(settings.idleMinutes) λεπτά σιωπής", value: $settings.idleMinutes, in: 1...30)
        }

        Section {
          Picker("Ανάγνωση εικόνας με", selection: $settings.visionEngine) {
            ForEach(Settings.VisionEngine.allCases) { Text($0.label).tag($0) }
          }
          Toggle("Ζωντανή κάμερα (1 καρέ/δευτ.)", isOn: $settings.liveCamera)
        } header: {
          Text("Κάμερα")
        } footer: {
          Text("Η ζωντανή κάμερα ξοδεύει περισσότερη μπαταρία στα γυαλιά. Χωρίς αυτήν, ο Jarvis τραβάει φωτογραφία μόνο όταν χρειάζεται.")
        }

        Section("Claude") {
          TextField("Μοντέλο", text: $settings.claudeModel)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          Toggle("Αναζήτηση στο web", isOn: $settings.claudeWebSearch)
        }

        Section {
          TextField("Μοντέλο Gemini Live", text: $settings.geminiModel)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          Toggle("Google Search στο Gemini (μόνο με χρέωση)", isOn: $settings.geminiSearch)
        } header: {
          Text("Για προχωρημένους")
        } footer: {
          Text("Αν η Google αλλάξει όνομα μοντέλου, γράψε εδώ το νέο (π.χ. gemini-3.8-live).")
        }

        Section("Γυαλιά") {
          LabeledContent("Συνδεδεμένα με Meta AI", value: glasses.isRegistered ? "Ναι" : "Όχι")
          LabeledContent("Βρέθηκαν τώρα", value: glasses.hasActiveDevice ? "Ναι" : "Όχι")
          LabeledContent("Άδεια κάμερας", value: glasses.cameraPjarvissionGranted ? "Ναι" : "Όχι")
          if glasses.isRegistered {
            Button("Αποσύνδεση γυαλιών από τον Jarvis", role: .destructive) { glasses.disconnect() }
          } else {
            Button("Σύνδεση γυαλιών") { glasses.connect() }
          }
          Button("Καθαρισμός συνομιλίας") { app.clearTranscript() }
        }
      }
      .navigationTitle("Ρυθμίσεις")
      .toolbar { Button("Τέλος") { dismiss() } }
    }
  }
}
