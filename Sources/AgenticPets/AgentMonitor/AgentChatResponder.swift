import Foundation

/// Answers user questions about what their coding agent is doing. Uses OpenAI's
/// chat completions API when OPENAI_API_KEY is set in the environment; otherwise
/// falls back to a plain status readout so the feature still works with no key.
enum AgentChatResponder {
    static func answer(question: String, currentState: AgentActivityState, completion: @escaping (String) -> Void) {
        let statusText: String
        switch currentState {
        case .idle:
            statusText = "No coding agent appears to be active right now."
        case .working(let summary):
            statusText = "Current agent activity: \(summary)."
        }

        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty,
              let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(statusText + " (Set OPENAI_API_KEY to let me actually answer questions.)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": "You are a friendly desktop pet that helps a developer understand what their AI coding agent is currently doing. Answer in 1-3 short sentences. Current status: \(statusText)"],
                ["role": "user", "content": question]
            ],
            "max_tokens": 150
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                DispatchQueue.main.async { completion(statusText + " (Couldn't reach OpenAI just now.)") }
                return
            }
            DispatchQueue.main.async { completion(content.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }.resume()
    }
}
