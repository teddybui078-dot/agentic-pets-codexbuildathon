import AppKit
import AVFoundation

/// Renders the pet itself: a looping video (idle by default, hover on mouse-over),
/// with a graceful fallback to a static image (or nothing) if assets are missing.
final class PetView: NSView {

    private static let idleAssetName = "pet-idle"
    private static let hoverAssetName = "pet-hover"
    private static let staticAssetName = "pet"
    private static let videoExtension = "mp4"
    private static let imageExtension = "png"

    private let playerLayer = AVPlayerLayer()
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?

    private var fallbackImageLayer: CALayer?
    private var trackingArea: NSTrackingArea?
    private var currentRate: Float = 1.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)

        play(assetNamed: Self.idleAssetName, fallbackToStaticImage: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        fallbackImageLayer?.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let newArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newArea)
        trackingArea = newArea
    }

    override func mouseEntered(with event: NSEvent) {
        // Only swap if a hover asset actually exists; otherwise keep looping idle.
        if resourceURL(named: Self.hoverAssetName, extension: Self.videoExtension) != nil {
            play(assetNamed: Self.hoverAssetName, fallbackToStaticImage: false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        play(assetNamed: Self.idleAssetName, fallbackToStaticImage: true)
    }

    /// Subtly adjusts playback speed; used by PetWindowController.setMood as a
    /// lightweight stand-in for a fuller mood system.
    func setPlaybackRate(_ rate: Float) {
        currentRate = rate
        guard let player = queuePlayer, player.rate != 0 else { return }
        player.rate = rate
    }

    // MARK: - Playback

    private func play(assetNamed name: String, fallbackToStaticImage: Bool) {
        guard let url = resourceURL(named: name, extension: Self.videoExtension) else {
            if fallbackToStaticImage {
                showStaticFallbackIfAvailable()
            }
            return
        }

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        let looper = AVPlayerLooper(player: player, templateItem: item)

        queuePlayer = player
        playerLooper = looper
        playerLayer.player = player

        player.isMuted = true
        player.play()
        player.rate = currentRate

        fallbackImageLayer?.isHidden = true
    }

    private func showStaticFallbackIfAvailable() {
        guard let url = resourceURL(named: Self.staticAssetName, extension: Self.imageExtension),
              let image = NSImage(contentsOf: url) else {
            // No video, no static image: just show nothing rather than crash.
            return
        }

        let imageLayer = fallbackImageLayer ?? CALayer()
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.frame = bounds
        if fallbackImageLayer == nil {
            layer?.addSublayer(imageLayer)
            fallbackImageLayer = imageLayer
        }
        imageLayer.isHidden = false
    }

    private func resourceURL(named name: String, extension ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
    }
}

/// Small rounded speech-bubble content view used by PetWindowController.showBubble.
final class PetBubbleView: NSView {

    private let label: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        field.textColor = .labelColor
        field.backgroundColor = .clear
        field.isBezeled = false
        field.isEditable = false
        field.alignment = .center
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 3
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        label.stringValue = text
    }
}
