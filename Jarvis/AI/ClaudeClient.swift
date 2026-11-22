import Foundation

/// Calls Claude (Anthropic Messages API) for the harder jobs: maths/physics step by step,
/// reading long Greek text from a photo, writing, research with web search.
struct ClaudeClient {
  enum ClaudeError: LocalizedError {
    case missingKey
    case http(Int, String)
    case empty
    var errorDescription: String? {
      switch self {
      case .missingKey: return "Δεν έχει μπει κλειδί Claude στις Ρυθμίσεις."
      case .http(let code, let message): return "Claude σφάλμα \(code): \(message)"
      case .empty: return "Ο Claude δεν έδωσε απάντηση."
      }
    }
  }

  var apiKey: String
  var model: String
  var webSearch: Bool

  func ask(_ prompt: String, imageJPEG: Data? = nil, system: String) async throws -> String {
    guard !apiKey.isEmpty else { throw ClaudeError.missingKey }
    do {
      return try await send(prompt, imageJPEG: imageJPEG, system: system, withTools: webSearch)
    } catch ClaudeError.http(let code, let message) where code == 400 && webSearch {
      // If the web-search tool isn't available on this account/model, retry without it.
      _ = message
      return try await send(prompt, imageJPEG: imageJPEG, system: system, withTools: false)
    }
  }

  private func send(_ prompt: String, imageJPEG: Data?, system: String, withTools: Bool) async throws
    -> String
  {
    var content: [[String: Any]] = []
    if let imageJPEG {
      content.append([
        "type": "image",
        "source": ["type": "base64", "media_type": "image/jpeg", "data": imageJPEG.base64EncodedString()],
      ])
    }
    content.append(["type": "text", "text": prompt])

    var body: [String: Any] = [
      "model": model,
      "max_tokens": 2500,
      "system": system,
      "messages": [["role": "user", "content": content]],
    ]
    if withTools {
      body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]]
    }

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    guard code == 200 else {
      let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "άγνωστο"
      throw ClaudeError.http(code, message)
    }
    let blocks = json?["content"] as? [[String: Any]] ?? []
    let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw ClaudeError.empty }
    return text
  }
}
