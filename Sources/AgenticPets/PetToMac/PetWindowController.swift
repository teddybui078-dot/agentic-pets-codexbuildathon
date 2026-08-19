import AppKit

/// Owns the floating pet window: a small, always-on-top, transparent, draggable
/// NSPanel docked next to the display notch (or top-center on notch-less
/// screens), plus a speech-bubble/mini-chat overlay driven by `showBubble(text:)`.
public final class PetWindowController: NSObject, PetWindowControlling {

    private static let defaultPetSize: CGFloat = 140
    private static let notchMargin: CGFloat = 6
    private static let petSizeDefaultsKey = "AgenticPets.petSize"

    private let panel: NSPanel
    private let petView: PetView
    private var petSize: CGFloat

    private var bubblePanel: NSPanel?
    private var isBubbleVisible = false

    /// Fired when the user types a question into the bubble's chat input.
    public var onAskQuestion: ((String) -> Void)?

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

        // Keep the bubble glued to the pet's head as it's dragged or resized.
        NotificationCenter.default.addObserver(
            self, selector: #selector(petFrameChanged), name: NSWindow.didMoveNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(petFrameChanged), name: NSWindow.didResizeNotification, object: panel
        )

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

    @objc private func petFrameChanged() {
        guard isBubbleVisible, let bubble = bubblePanel else { return }
        positionBubble(bubble)
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
        menu.addItem(.separator())
        let askItem = NSMenuItem(title: "Ask about my agents…", action: #selector(askMenuItemSelected), keyEquivalent: "")
        askItem.target = self
        menu.addItem(askItem)
        return menu
    }

    @objc private func sizePresetSelected(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        setPetSize(CGFloat(number.doubleValue))
    }

    @objc private func askMenuItemSelected() {
        showBubble(text: "What would you like to know about your coding agents?")
        (bubblePanel?.contentView as? PetBubbleView)?.focusInput()
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

    /// Shows (or updates) the bubble. It stays up until the user dismisses it —
    /// there's no auto-hide timer — and tracks the pet if it's moved or resized.
    public func showBubble(text: String) {
        let bubble = bubblePanel ?? makeBubblePanel()
        bubblePanel = bubble
        isBubbleVisible = true

        if let bubbleView = bubble.contentView as? PetBubbleView {
            bubbleView.setText(text)
            bubble.setContentSize(bubbleView.fittingSize())
        }

        positionBubble(bubble)
        bubble.alphaValue = 1
        // makeKeyAndOrderFront (not just orderFrontRegardless) so the input field can
        // actually receive keystrokes — .nonactivatingPanel means this still won't
        // steal focus from, or activate over, whatever app the user is working in.
        bubble.makeKeyAndOrderFront(nil)
    }

    public func setMood(working: Bool) {
        // No fancy mood system yet: just nudge playback speed a little while "working".
        petView.setPlaybackRate(working ? 1.15 : 1.0)
    }

    // MARK: - Bubble

    private func makeBubblePanel() -> NSPanel {
        let initialSize = NSSize(width: PetBubbleView.width, height: 44)
        let bubbleView = PetBubbleView(frame: NSRect(origin: .zero, size: initialSize))
        bubbleView.onClose = { [weak self] in self?.hideBubble() }
        bubbleView.onAsk = { [weak self] question in self?.onAskQuestion?(question) }

        let bubble = ChatBubblePanel(
            contentRect: bubbleView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        bubble.level = .statusBar
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = true
        bubble.hidesOnDeactivate = false
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bubble.contentView = bubbleView
        return bubble
    }

    private func hideBubble() {
        isBubbleVisible = false
        bubblePanel?.orderOut(nil)
    }

    private func positionBubble(_ bubble: NSPanel) {
        let panelFrame = panel.frame
        let size = bubble.frame.size
        let gap: CGFloat = 8

        // Anchor to the top of the character's head, not the whole (mostly
        // transparent) square, so the bubble sits right over the pet.
        let headTopY = panelFrame.maxY - petSize * PetView.headTopFraction

        // The pet can dock flush against the top of the screen (by the notch),
        // which leaves no room above — flip below in that case.
        let screenMaxY = NSScreen.main?.visibleFrame.maxY ?? .greatestFiniteMagnitude
        let fitsAbove = headTopY + gap + size.height <= screenMaxY
        let originY = fitsAbove ? headTopY + gap : panelFrame.minY - gap - size.height

        let origin = NSPoint(x: panelFrame.midX - size.width / 2, y: originY)
        bubble.setFrameOrigin(origin)
    }
}

/// Plain NSPanel with a borderless, non-activating style mask doesn't reliably
/// accept key status by default, which is what let the bubble show up but never
/// actually take keystrokes for its chat input. Forcing it here fixes that.
private final class ChatBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
