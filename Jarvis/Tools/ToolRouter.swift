import UIKit

/// The actions Gemini can ask the app to perform, and how each one runs.
@MainActor
final class ToolRouter {
  private unowned let app: AppModel

  init(app: AppModel) {
    self.app = app
  }

  // Built from small helpers so the Swift compiler doesn't choke on one giant literal.
  private static func string(_ description: String) -> [String: Any] {
    ["type": "STRING", "description": description]
  }

  private static func function(
    _ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []
  ) -> [String: Any] {
    var declaration: [String: Any] = ["name": name, "description": description]
    guard !properties.isEmpty else { return declaration }  // no-argument function
    var parameters: [String: Any] = ["type": "OBJECT", "properties": properties]
    if !required.isEmpty { parameters["required"] = required }
    declaration["parameters"] = parameters
    return declaration
  }

  static var declarations: [[String: Any]] {
    var list: [[String: Any]] = []
    list.append(
      function(
        "look",
        "Τραβάει φωτογραφία από την κάμερα των γυαλιών για να δεις τι βλέπει ο χρήστης. Για περιγραφή, ανάγνωση κειμένου (και ελληνικών), αντικείμενα, τιμές, πινακίδες.",
        ["question": string("Τι θέλει να μάθει ο χρήστης για την εικόνα.")],
        required: ["question"]))

    var includePhoto: [String: Any] = ["type": "BOOLEAN"]
    includePhoto["description"] = "true αν η εργασία αφορά κάτι που βλέπει ο χρήστης (π.χ. άσκηση σε βιβλίο)."
    list.append(
      function(
        "ask_claude",
        "Στέλνει δύσκολη δουλειά στον Claude: μαθηματικά, φυσική, ασκήσεις βήμα-βήμα, μεγάλα κείμενα, γράψιμο, προγραμματισμό, έρευνα. Επιστρέφει την απάντηση σε κείμενο.",
        [
          "task": string("Η πλήρης εργασία/ερώτηση, με όλο το απαραίτητο πλαίσιο."),
          "include_photo": includePhoto,
        ],
        required: ["task"]))

    var appProperty = string("Εφαρμογή αποστολής: sms, whatsapp ή viber.")
    appProperty["enum"] = ["sms", "whatsapp", "viber"]
    list.append(
      function(
        "send_message",
        "Ετοιμάζει μήνυμα προς μια επαφή. Το iPhone απαιτεί ο χρήστης να πατήσει Αποστολή.",
        [
          "contact": string("Όνομα επαφής όπως είναι στις Επαφές (π.χ. «Μαρία»)."),
          "message": string("Το κείμενο του μηνύματος."),
          "app": appProperty,
        ],
        required: ["contact", "message", "app"]))

    list.append(
      function(
        "save_note", "Αποθηκεύει μια σημείωση στο κινητό.",
        ["text": string("Η σημείωση.")], required: ["text"]))

    list.append(
      function(
        "run_shortcut", "Τρέχει μια Συντόμευση (Shortcut) του iPhone με το όνομά της.",
        [
          "name": string("Ακριβές όνομα της Συντόμευσης."),
          "input": string("Προαιρετικό κείμενο εισόδου."),
        ],
        required: ["name"]))

    list.append(function("end_conversation", "Τερματίζει τη συνομιλία όταν ο χρήστης αποχαιρετά."))
    return list
  }

  func handle(_ call: GeminiLiveClient.ToolCall) async -> [String: Any] {
    switch call.name {
    case "look":
      return await look(question: call.args["question"] as? String ?? "Περιέγραψε τι βλέπω.")
    case "ask_claude":
      return await askClaude(
        task: call.args["task"] as? String ?? "",
        includePhoto: call.args["include_photo"] as? Bool ?? false)
    case "send_message":
      let result = await MessageSender.shared.prepareMessage(
        contact: call.args["contact"] as? String ?? "",
        text: call.args["message"] as? String ?? "",
        app: call.args["app"] as? String ?? "sms")
      app.log(.system, "✉️ \(result)")
      return ["result": result]
    case "save_note":
      let text = call.args["text"] as? String ?? ""
      guard !text.isEmpty else { return ["error": "Κενή σημείωση."] }
      NotesStore.shared.add(text)
      app.log(.system, "📝 \(text)")
      return ["result": "Αποθηκεύτηκε."]
    case "run_shortcut":
      let result = MessageSender.shared.prepareShortcut(
        name: call.args["name"] as? String ?? "", input: call.args["input"] as? String)
      app.log(.system, "⚡️ \(result)")
      return ["result": result]
    case "end_conversation":
      app.stopAfterGoodbye()
      return ["result": "Η συνομιλία θα κλείσει σε λίγα δευτερόλεπτα."]
    default:
      return ["error": "Άγνωστο εργαλείο \(call.name)"]
    }
  }

  // MARK: - Tools

  private func look(question: String) async -> [String: Any] {
    app.log(.system, "📷 Τραβάω φωτογραφία…")
    guard let image = await app.glasses.captureImage() else {
      let reason = app.glasses.lastError ?? "άγνωστο σφάλμα"
      app.log(.system, "⚠️ \(reason)")
      return ["error": "Δεν μπόρεσα να πάρω εικόνα από τα γυαλιά: \(reason)"]
    }
    app.lastPhoto = image

    if Settings.shared.visionEngine == .claude && Settings.shared.hasClaudeKey {
      guard let jpeg = image.jpegForAI(maxSide: 1568, quality: 0.8) else { return ["error": "Σφάλμα εικόνας."] }
      do {
        let answer = try await app.claude().ask(
          "Ερώτηση του χρήστη για αυτό που βλέπει: \(question)\nΑπάντησε σύντομα, για να ειπωθεί φωναχτά.",
          imageJPEG: jpeg, system: Prompts.claudeSystem)
        app.log(.claude, answer)
        return ["result": answer]
      } catch {
        return ["error": error.localizedDescription]
      }
    }

    guard let jpeg = image.jpegForAI(maxSide: 1024, quality: 0.75) else { return ["error": "Σφάλμα εικόνας."] }
    app.gemini?.sendImage(jpeg: jpeg)
    return [
      "result":
        "Η φωτογραφία από τα γυαλιά μόλις στάλθηκε ως εικόνα στη συνομιλία. Κοίτα την και απάντησε στο: \(question)"
    ]
  }

  private func askClaude(task: String, includePhoto: Bool) async -> [String: Any] {
    guard Settings.shared.hasClaudeKey else {
      return ["error": "Δεν έχει ρυθμιστεί κλειδί Claude. Απάντησε όσο καλύτερα μπορείς μόνος σου."]
    }
    var jpeg: Data?
    if includePhoto {
      app.log(.system, "📷 Τραβάω φωτογραφία για τον Claude…")
      if let image = await app.glasses.captureImage() {
        app.lastPhoto = image
        jpeg = image.jpegForAI(maxSide: 1568, quality: 0.85)
      }
    }
    app.log(.system, "🧠 Ρωτάω τον Claude…")
    do {
      let answer = try await app.claude().ask(task, imageJPEG: jpeg, system: Prompts.claudeSystem)
      app.log(.claude, answer)
      let spoken = answer.count > 6000 ? String(answer.prefix(6000)) + "…" : answer
      return [
        "result": spoken,
        "instruction": "Πες στον χρήστη σύντομα το αποτέλεσμα. Η πλήρης λύση φαίνεται γραπτά στο κινητό.",
      ]
    } catch {
      app.log(.system, "⚠️ \(error.localizedDescription)")
      return ["error": error.localizedDescription]
    }
  }
}

extension UIImage {
  func jpegForAI(maxSide: CGFloat, quality: CGFloat) -> Data? {
    let longest = max(size.width, size.height)
    guard longest > 0 else { return nil }
    let scale = min(1, maxSide / longest)
    if scale >= 1 { return jpegData(compressionQuality: quality) }
    let target = CGSize(width: size.width * scale, height: size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: target))
    }
    return resized.jpegData(compressionQuality: quality)
  }
}
