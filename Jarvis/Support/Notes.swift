import Foundation

/// Simple on-phone notes ("Jarvis, σημείωσε ότι...").
@MainActor
final class NotesStore: ObservableObject {
  static let shared = NotesStore()

  struct Note: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var text: String
  }

  @Published private(set) var notes: [Note] = []
  private let key = "notes.v1"

  private init() {
    if let data = UserDefaults.standard.data(forKey: key),
      let saved = try? JSONDecoder().decode([Note].self, from: data)
    {
      notes = saved
    }
  }

  func add(_ text: String) {
    notes.insert(Note(text: text), at: 0)
    persist()
  }

  func delete(at offsets: IndexSet) {
    notes.remove(atOffsets: offsets)
    persist()
  }

  /// Recent notes, so Jarvis can answer "τι είχα σημειώσει;".
  func summary(limit: Int = 15) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "el_GR")
    f.dateFormat = "d MMM HH:mm"
    return notes.prefix(limit).map { "- [\(f.string(from: $0.date))] \($0.text)" }.joined(separator: "\n")
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(notes) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }
}
