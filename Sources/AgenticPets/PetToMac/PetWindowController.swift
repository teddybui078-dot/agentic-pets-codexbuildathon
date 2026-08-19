import AppKit

/// Owns the floating pet window: a small, always-on-top, transparent, draggable
/// NSPanel docked next to the display notch (or top-center on notch-less
/// screens), plus a lightweight speech-bubble overlay driven by `showBubble(text:)`.
public final class PetWindowController: NSObject, PetWindowControlling {

    private static let defaultPetSize: CGFloat = 140
    private static let notchMargin: CGFloat = 6
    private static let bubbleVisibleDuration: TimeInterval = 6
    private static let bubbleSize = NSSize(width: 200, height: 60)
    private static let petSizeDefaultsKey = "AgenticPets.petSize"

    private let panel: NSPanel
    private let petView: PetView
    private var petSize: CGFloat

    private var bubblePanel: NSPanel?
    private var bubbleHideWorkItem: DispatchWorkItem?

    public override init() {
        let savedSize = UserDefaults.standard.double(forKey: Self.petSizeDefaultsKey)
        let initialSize = savedSize >= Double(PetView.minSize) ? CGFloat(savedSize) : Self.defaultPetSize
        petSize = initialSize

        let view = PetView(frame: NSRect(origin: .zero, size: NSSize(width: initialSize, height: initialSize)))
        petView = view

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: initialSize, height: initialSize)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = view
        self.panel = panel

        super.init()

        view.onResizeRequest = { [weak self] delta in
            self?.adjustPetSize(byPointDelta: delta)
        }
        view.menu = makeSizeMenu()

        positionNearNotch()
        panel.orderFrontRegardless()
    }

    /// Sets the pet's on-screen size directly (points, applied to both width and height),
    /// clamped to a sane range, resizing around its current center.
    public func setPetSize(_ size: CGFloat) {
        let clamped = min(max(size, PetView.minSize), PetView.maxSize)
        guard clamped != petSize else { return }
        petSize = clamped

        // Resize around the current center so it doesn't jump if the user dragged it.
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let newFrame = NSRect(
            x: center.x - clamped / 2,
            y: center.y - clamped / 2,
            width: clamped,
            height: clamped
        )
        panel.setFrame(newFrame, display: true)

        UserDefaults.standard.set(Double(clamped), forKey: Self.petSizeDefaultsKey)
    }

    private func adjustPetSize(byPointDelta delta: CGFloat) {
        // Scroll up/away grows the pet, scroll down/toward shrinks it.
        setPetSize(petSize + delta)
    }

    // MARK: - Size menu

    private func makeSizeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for preset in PetView.sizePresets {
            let item = NSMenuItem(title: preset.label, action: #selector(sizePresetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: Double(preset.size))
            menu.addItem(item)
        }
        return menu
    }

    @objc private func sizePresetSelected(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        setPetSize(CGFloat(number.doubleValue))
    }

    /// Docks the pet just to the right of the notch, inside the menu-bar strip, on
    /// screens that have one. Falls back to top-center on notch-less displays.
    private func positionNearNotch() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let originY = screenFrame.maxY - petSize

        var originX = screenFrame.midX - petSize / 2
        if #available(macOS 12.0, *) {
            let rightOfNotch = screen.auxiliaryTopRightArea
            if let rightOfNotch, rightOfNotch.width > 0 {
                originX = rightOfNotch.minX + Self.notchMargin
            }
        }

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    // MARK: - PetWindowControlling

    public func showBubble(text: String) {
        bubbleHideWorkItem?.cancel()

        let bubble = bubblePanel ?? makeBubblePanel()
        bubblePanel = bubble

        if let bubbleView = bubble.contentView as? PetBubbleView {
            bubbleView.setText(text)
        }

        positionBubble(bubble)
        bubble.alphaValue = 1
        bubble.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            self?.bubblePanel?.orderOut(nil)
        }
        bubbleHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bubbleVisibleDuration, execute: workItem)
    }

    public func setMood(working: Bool) {
        // No fancy mood system yet: just nudge playback speed a little while "working".
        petView.setPlaybackRate(working ? 1.15 : 1.0)
    }

    // MARK: - Bubble

    private func makeBubblePanel() -> NSPanel {
        let bubbleView = PetBubbleView(frame: NSRect(origin: .zero, size: Self.bubbleSize))

        let bubble = NSPanel(
            contentRect: bubbleView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        bubble.level = .statusBar
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = true
        bubble.ignoresMouseEvents = true
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bubble.contentView = bubbleView
        return bubble
    }

    private func positionBubble(_ bubble: NSPanel) {
        let panelFrame = panel.frame
        let size = bubble.frame.size
        let origin = NSPoint(
            x: panelFrame.midX - size.width / 2,
            y: panelFrame.maxY + 8
        )
        bubble.setFrameOrigin(origin)
    }
}

extension PetWindowController: NSMenuDelegate {
    /// Checkmarks the preset matching the pet's current size.
    public func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            guard let number = item.representedObject as? NSNumber else { continue }
            item.state = abs(CGFloat(number.doubleValue) - petSize) < 0.5 ? .on : .off
        }
    }
}
