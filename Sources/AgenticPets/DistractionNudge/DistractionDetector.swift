import AppKit
import Foundation

/// Watches which app is frontmost and nudges the user if they linger in a
/// browser (a likely distraction) while a coding agent is presumably still
/// working in the background.
final class DistractionDetector: DistractionObserving {

    var onDistracted: ((String) -> Void)?

    /// Bundle identifiers we consider "distracting" browsers.
    private let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser" // Arc
    ]

    /// How long a browser must stay frontmost, continuously, before we nudge.
    private let distractionThreshold: TimeInterval = 15

    private var pendingWorkItem: DispatchWorkItem?
    private var observerToken: NSObjectProtocol?

    deinit {
        stop()
    }

    func start() {
        // Avoid double-registering if start() is called more than once.
        stop()

        observerToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleActivation(notification)
        }
    }

    func stop() {
        if let token = observerToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            observerToken = nil
        }
        cancelPendingNudge()
    }

    private func handleActivation(_ notification: Notification) {
        let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .bundleIdentifier

        // Whatever was pending is no longer valid once the frontmost app changes.
        cancelPendingNudge()

        guard let bundleID, browserBundleIDs.contains(bundleID) else {
            // Switched to something that isn't a tracked browser — nothing to do.
            return
        }

        scheduleNudge(for: bundleID)
    }

    private func scheduleNudge(for bundleID: String) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.fireNudge(for: bundleID)
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + distractionThreshold, execute: workItem)
    }

    private func cancelPendingNudge() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    }

    private func fireNudge(for bundleID: String) {
        pendingWorkItem = nil

        if bundleID == "com.google.Chrome", let youtubeMessage = youtubeNudgeMessage() {
            onDistracted?(youtubeMessage)
            return
        }

        onDistracted?(
            "Hey! I noticed you switched away — your agent's still working, want a summary of what it's doing?"
        )
    }

    /// Best-effort peek at Chrome's active tab via AppleScript. Returns a
    /// YouTube-flavored nudge message if the active tab is youtube.com,
    /// otherwise nil (falling back to the generic nudge).
    private func youtubeNudgeMessage() -> String? {
        let script = """
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            set activeTab to active tab of front window
            set tabURL to URL of activeTab
            set tabTitle to title of activeTab
            return tabURL & "|||" & tabTitle
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else { return nil }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        guard errorInfo == nil, let output = result.stringValue, !output.isEmpty else {
            return nil
        }

        let parts = output.components(separatedBy: "|||")
        guard let urlString = parts.first, urlString.contains("youtube.com") else {
            return nil
        }

        let title = parts.count > 1 ? parts[1] : "a video"
        return "Hey! I see you're watching \"\(title)\" on YouTube — your agent's still working. Want a quick status update when you're back?"
    }
}
