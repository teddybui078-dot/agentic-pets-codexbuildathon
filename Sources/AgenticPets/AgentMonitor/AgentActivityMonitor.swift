import Foundation

/// Polls the system for signs that a coding agent (Claude Code, Codex, Cursor, etc.)
/// is currently running and, if so, tries to figure out what it's doing.
///
/// Heuristics used (intentionally rough, not bulletproof):
///  1. Shell out to `ps aux` and grep for known agent binary/process names.
///  2. Look for the most recently modified `.jsonl` session log under
///     `~/.claude/projects/**/*.jsonl`. If it was touched in roughly the last
///     60 seconds, treat that as evidence of an active session, and try to
///     pull a short summary out of the last line of that file (parsed as JSON).
final class AgentActivityMonitor: AgentActivityObserving {

    var onActivityChange: ((AgentActivityState) -> Void)?

    /// How often to poll for agent activity.
    private let pollInterval: TimeInterval = 2.0

    /// How recent a session log's last modification needs to be to count as "active".
    private let recentActivityWindow: TimeInterval = 60.0

    /// Lowercased substrings we look for in `ps aux` output to detect a running agent.
    private let knownAgentProcessNames = ["claude", "codex", "cursor"]

    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.agenticpets.agentmonitor", qos: .utility)

    /// A running process name is a weak signal — e.g. Claude Code itself is always
    /// "running" for the entire session whether it's idle at a prompt or mid-task,
    /// and the same goes for a Codex terminal just sitting there. So on every poll
    /// where the process/log heuristic says an agent *might* be active, we OCR the
    /// screen (cheap, local, no network) and diff it against the last snapshot: if
    /// the visible text hasn't changed in a while, it's idle regardless of what
    /// processes exist.
    private let activeIdleWindow: TimeInterval = 8.0
    private var lastOCRSnapshot: String?
    private var lastOCRChangeAt = Date.distantPast

    /// The OpenAI call to turn OCR text into a specific summary is the expensive
    /// part (network), so it's throttled separately and less aggressively.
    private let ocrSummaryRefreshInterval: TimeInterval = 8.0
    private var lastOCRSummaryAt: Date?

    func start() {
        // Run an initial check right away, then poll on a repeating timer.
        pollOnce()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pollOnce() {
        queue.async { [weak self] in
            guard let self else { return }
            let state = self.computeCurrentState()
            DispatchQueue.main.async {
                self.onActivityChange?(state)
            }
            if case .working = state {
                self.maybeRefineWithOCR()
            }
        }
    }

    private func maybeRefineWithOCR() {
        let now = Date()
        if let last = lastOCRSummaryAt, now.timeIntervalSince(last) < ocrSummaryRefreshInterval { return }
        lastOCRSummaryAt = now

        AgentChatResponder.describeCurrentWork { [weak self] description in
            guard let self, let description else { return }
            self.onActivityChange?(.working(summary: description))
        }
    }

    // MARK: - State computation

    private func computeCurrentState() -> AgentActivityState {
        let processIsRunning = isKnownAgentProcessRunning()
        let recentLog = mostRecentlyModifiedSessionLog()

        let logIsRecent: Bool
        if let recentLog {
            let age = Date().timeIntervalSince(recentLog.modifiedAt)
            logIsRecent = age >= 0 && age <= recentActivityWindow
        } else {
            logIsRecent = false
        }

        guard processIsRunning || logIsRecent else {
            return .idle
        }

        // Process/log presence is weak on its own (a Codex terminal or a Claude Code
        // session stays "running" whether it's idle at a prompt or mid-task) — refine
        // with on-screen activity: no visible change recently means actually idle.
        if !isScreenActivelyChanging() {
            return .idle
        }

        if logIsRecent, let recentLog, let summary = summarize(sessionLogAt: recentLog.url) {
            return .working(summary: summary)
        }

        return .working(summary: "your coding agent is working")
    }

    /// Updates the OCR change-tracking snapshot and reports whether the screen has
    /// visibly changed within `activeIdleWindow`. If OCR itself is unavailable (e.g.
    /// Screen Recording permission not granted), falls back to "true" so we don't
    /// regress to always-idle without that signal.
    private func isScreenActivelyChanging() -> Bool {
        guard let currentText = ScreenTextReader.captureScreenText() else { return true }

        if currentText != lastOCRSnapshot {
            lastOCRSnapshot = currentText
            lastOCRChangeAt = Date()
        }

        return Date().timeIntervalSince(lastOCRChangeAt) <= activeIdleWindow
    }

    // MARK: - Process detection

    private func isKnownAgentProcessRunning() -> Bool {
        guard let output = runProcess("/bin/ps", arguments: ["aux"]) else {
            return false
        }

        let lowercasedOutput = output.lowercased()
        for line in lowercasedOutput.split(separator: "\n") {
            // Skip the line for this grep-like check itself / obviously unrelated matches
            // by requiring the known name to appear as part of a path/command token.
            for name in knownAgentProcessNames {
                if line.contains(name) {
                    return true
                }
            }
        }
        return false
    }

    private func runProcess(_ launchPath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8)
    }

    // MARK: - Session log discovery

    private struct SessionLog {
        let url: URL
        let modifiedAt: Date
    }

    /// Walks `~/.claude/projects/**/*.jsonl` and returns the most recently modified file.
    private func mostRecentlyModifiedSessionLog() -> SessionLog? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")

        guard let enumerator = fileManager.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return nil
        }

        var best: SessionLog?

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }

            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else {
                continue
            }

            if best == nil || modifiedAt > best!.modifiedAt {
                best = SessionLog(url: fileURL, modifiedAt: modifiedAt)
            }
        }

        return best
    }

    // MARK: - Summary extraction

    /// Tries to read the last line of the session log and pull a short summary out of it.
    /// Returns nil if the file can't be read or the last line can't be parsed usefully.
    private func summarize(sessionLogAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        guard let lastLine = lines.last else { return nil }

        guard let lineData = lastLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }

        if let summary = extractSummary(from: json) {
            return summary
        }
        return nil
    }

    /// Best-effort extraction of a short one-line summary from a parsed JSONL session entry.
    /// The exact schema of Claude Code's session logs isn't guaranteed, so this probes a
    /// handful of plausible shapes and falls back to nil (caller supplies a generic string).
    private func extractSummary(from json: [String: Any]) -> String? {
        // Look inside a nested "message" object first (common shape for session entries).
        let candidateContainers: [[String: Any]] = [json, json["message"] as? [String: Any]].compactMap { $0 }

        for container in candidateContainers {
            // Direct string fields that might hold a useful snippet.
            for key in ["summary", "text"] {
                if let value = container[key] as? String, !value.isEmpty {
                    return truncate(oneLine(value))
                }
            }

            // "content" can be a string, or an array of content blocks (tool_use, text, etc).
            if let contentString = container["content"] as? String, !contentString.isEmpty {
                return truncate(oneLine(contentString))
            }

            if let contentBlocks = container["content"] as? [[String: Any]] {
                for block in contentBlocks {
                    if let toolName = block["name"] as? String, !toolName.isEmpty {
                        return truncate("using \(toolName)")
                    }
                    if let text = block["text"] as? String, !text.isEmpty {
                        return truncate(oneLine(text))
                    }
                }
            }

            // Some tool-related entries carry a top-level tool name.
            if let toolName = container["tool_name"] as? String ?? container["toolName"] as? String,
               !toolName.isEmpty {
                return truncate("using \(toolName)")
            }
        }

        return nil
    }

    private func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ text: String, limit: Int = 80) -> String {
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index]) + "…"
    }
}
