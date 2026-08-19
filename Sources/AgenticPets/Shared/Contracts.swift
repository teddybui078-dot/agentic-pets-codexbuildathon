import Foundation

/// What a coding agent is currently doing, as reported by AgentActivityMonitor.
enum AgentActivityState {
    case idle
    case working(summary: String)
}

/// Implemented by AgentActivityMonitor. Reports whether a coding agent is active.
protocol AgentActivityObserving: AnyObject {
    var onActivityChange: ((AgentActivityState) -> Void)? { get set }
    func start()
}

/// Implemented by DistractionDetector. Fires when the user appears to have drifted away.
protocol DistractionObserving: AnyObject {
    var onDistracted: ((String) -> Void)? { get set }
    func start()
}

/// Implemented by PetWindowController. Lets other pieces drive the pet's visible state.
protocol PetWindowControlling: AnyObject {
    func showBubble(text: String)
    func setMood(working: Bool)
}
