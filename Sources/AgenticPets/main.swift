import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var petWindow: PetWindowController?
    private let agentMonitor = AgentActivityMonitor()
    private let distractionDetector = DistractionDetector()

    /// Only nudge the user if the agent was actually working when they drifted away.
    private var lastAgentState: AgentActivityState = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let petWindow = PetWindowController()
        self.petWindow = petWindow

        agentMonitor.onActivityChange = { [weak self] state in
            self?.lastAgentState = state
            switch state {
            case .idle:
                petWindow.setMood(working: false)
            case .working:
                petWindow.setMood(working: true)
            }
        }

        distractionDetector.onDistracted = { [weak self] message in
            guard case .working = self?.lastAgentState else { return }
            petWindow.showBubble(text: message)
        }

        petWindow.onAskQuestion = { [weak self] question in
            guard let self else { return }
            AgentChatResponder.answer(question: question, currentState: self.lastAgentState) { answer in
                petWindow.showBubble(text: answer)
            }
        }

        agentMonitor.start()
        distractionDetector.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
