import AppKit

// Bootstrap. Wiring of PetWindowController / AgentActivityMonitor / DistractionDetector
// happens here once their branches are merged in (see plan's Integration step).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
