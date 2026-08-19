import Foundation

/// Answers user questions about what their coding agent is doing, and produces
/// specific "what are they working on" summaries — both powered by OCR'ing the
/// screen (agent-agnostic: works for Codex, Claude Code, Cursor, anything visible
/// on screen) plus OpenAI's chat completions API (OPENAI_API_KEY from the
/// environment) to turn that raw text into something specific and readable.
/// Falls back to a plain status readout if no key is set or OCR finds nothing.
enum AgentChatResponder {
    static func answer(question: String, currentState: AgentActivityState, completion: @escaping (String) -> Void) {
        let baseStatus = statusText(for: currentState)
        let ocrText = ScreenTextReader.captureScreenText()
        let system = """
        You are a friendly desktop pet that helps a developer understand what their AI coding agent is currently doing. \
        Answer in 1-3 short, SPECIFIC sentences — name concrete features/files/topics you can see, not generic filler. \
        \(baseStatus)
        """
        callOpenAI(system: system, user: contextualUserMessage(question, ocrText: ocrText), fallback: baseStatus, completion: completion)
    }

    /// A specific one-sentence description of the coding task currently visible on
    /// screen, e.g. "wiring up the Google OAuth connector". Returns nil if there's
    /// no OCR text, no API key, or the screen doesn't look like agent activity.
    static func describeCurrentWork(completion: @escaping (String?) -> Void) {
        guard let ocrText = ScreenTextReader.captureScreenText(), !ocrText.isEmpty else {
            completion(nil)
            return
        }
        let prompt = """
        Screen OCR text:
        \(ocrText.prefix(2500))

        In ONE short, specific sentence, describe what coding task or feature the person is working \
        on right now (e.g. "wiring up the Google OAuth connector", "writing auth middleware tests"). \
        If this doesn't look like a coding agent / terminal / editor at all, reply exactly: unclear
        """
        callOpenAI(system: "You infer what coding task is being worked on from raw OCR'd screen text.", user: prompt, fallback: nil) { result in
            completion(result.lowercased() == "unclear" ? nil : result)
        }
    }

    private static func statusText(for state: AgentActivityState) -> String {
        switch state {
        case .idle:
            return "No coding agent appears to be active right now."
        case .working(let summary):
            return "Recent signal: \(summary)."
        }
    }

    private static func contextualUserMessage(_ question: String, ocrText: String?) -> String {
        guard let ocrText, !ocrText.isEmpty else { return question }
        return "\(question)\n\nHere's OCR'd text currently visible on my screen (my coding agent's terminal/window) — use it to be specific:\n\(ocrText.prefix(2500))"
    }

    private static func callOpenAI(system: String, user: String, fallback: String?, completion: @escaping (String) -> Void) {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty,
              let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(fallback ?? "(Set OPENAI_API_KEY to let me actually answer questions.)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
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
                DispatchQueue.main.async { completion(fallback ?? "(Couldn't reach OpenAI just now.)") }
                return
            }
            DispatchQueue.main.async { completion(content.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }.resume()
    }
}
