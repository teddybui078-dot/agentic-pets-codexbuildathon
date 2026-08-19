import AppKit
import AVFoundation
import CoreImage

/// Renders the pet itself: a looping video (idle by default, hover on mouse-over),
/// with a graceful fallback to a static image (or nothing) if assets are missing.
/// The video's near-white background is keyed out to transparency at playback time.
final class PetView: NSView {

    private static let idleAssetName = "pet-idle"
    private static let hoverAssetName = "pet-hover"
    private static let staticAssetName = "pet"
    private static let videoExtension = "mp4"
    private static let imageExtension = "png"

    static let minSize: CGFloat = 72
    static let maxSize: CGFloat = 360

    /// Fixed size presets offered via the right-click menu.
    static let sizePresets: [(label: String, size: CGFloat)] = [
        ("Small", 100), ("Medium", 160), ("Large", 240)
    ]

    /// Where the character actually sits within the square video frame (measured via
    /// ffmpeg cropdetect against the near-white background, plus padding for animation
    /// motion), as fractions of the view's bounds. Hover detection is scoped to this
    /// region so moving the cursor through the video's transparent margins doesn't
    /// trigger the hover effect.
    private static let characterRegionFraction = (minX: 0.195, maxX: 0.773, minYFromTop: 0.149, maxYFromTop: 0.858)

    /// Removes near-white pixels (the flat background the pet assets are rendered on)
    /// by turning them transparent; premultiplied-alpha output per Core Image convention.
    private static let chromaKeyKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 whiteChromaKey(__sample s) {
            float threshold = 0.15;
            float softness = 0.12;
            float dist = distance(s.rgb, vec3(1.0, 1.0, 1.0));
            float alpha = smoothstep(threshold, threshold + softness, dist);
            alpha = min(alpha, s.a);
            return vec4(s.rgb * alpha, alpha);
        }
        """)

    // Idle and hover each get their own player/layer, both created once and kept
    // running continuously in the background. Hovering just toggles which layer is
    // visible instead of tearing down and rebuilding a player pipeline on the fly —
    // that rebuild (new AVQueuePlayer + looper + chroma-key composition) isn't
    // instant, and doing it live on every hover was what caused the pet to visibly
    // blank out and reappear.
    private let idleLayer = AVPlayerLayer()
    private let hoverLayer = AVPlayerLayer()
    private var idlePlayer: AVQueuePlayer?
    private var idleLooper: AVPlayerLooper?
    private var hoverPlayer: AVQueuePlayer?
    private var hoverLooper: AVPlayerLooper?
    private var isHoverAvailable = false

    private var fallbackImageLayer: CALayer?
    private var trackingArea: NSTrackingArea?
    private var currentRate: Float = 1.0

    /// Called with a proposed size delta (points) when the user scrolls over the pet.
    var onResizeRequest: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        for playerLayer in [idleLayer, hoverLayer] {
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.clear.cgColor
            playerLayer.frame = bounds
            layer?.addSublayer(playerLayer)
        }
        hoverLayer.isHidden = true

        if let (player, looper) = Self.makeLoopingPlayer(assetNamed: Self.idleAssetName) {
            idlePlayer = player
            idleLooper = looper
            idleLayer.player = player
            player.isMuted = true
            player.play()
        } else {
            showStaticFallbackIfAvailable()
        }

        if let (player, looper) = Self.makeLoopingPlayer(assetNamed: Self.hoverAssetName) {
            hoverPlayer = player
            hoverLooper = looper
            hoverLayer.player = player
            player.isMuted = true
            player.play()
            isHoverAvailable = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        idleLayer.frame = bounds
        hoverLayer.frame = bounds
        fallbackImageLayer?.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let newArea = NSTrackingArea(
            rect: characterHitRegion,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newArea)
        trackingArea = newArea
    }

    /// The character's approximate footprint within `bounds` (AppKit is bottom-up,
    /// the measured fractions are top-down, so the Y axis is flipped here).
    private var characterHitRegion: NSRect {
        let f = Self.characterRegionFraction
        let x = bounds.width * f.minX
        let width = bounds.width * (f.maxX - f.minX)
        let y = bounds.height * (1 - f.maxYFromTop)
        let height = bounds.height * (f.maxYFromTop - f.minYFromTop)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isHoverAvailable else { return }
        idleLayer.isHidden = true
        hoverLayer.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        guard isHoverAvailable else { return }
        hoverLayer.isHidden = true
        idleLayer.isHidden = false
    }

    override func scrollWheel(with event: NSEvent) {
        onResizeRequest?(event.scrollingDeltaY)
    }

    /// Subtly adjusts playback speed; used by PetWindowController.setMood as a
    /// lightweight stand-in for a fuller mood system.
    func setPlaybackRate(_ rate: Float) {
        currentRate = rate
        for player in [idlePlayer, hoverPlayer] {
            guard let player, player.rate != 0 else { continue }
            player.rate = rate
        }
    }

    // MARK: - Playback

    private static func makeLoopingPlayer(assetNamed name: String) -> (AVQueuePlayer, AVPlayerLooper)? {
        guard let url = Bundle.module.url(forResource: name, withExtension: videoExtension, subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: videoExtension) else {
            return nil
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = makeChromaKeyComposition(for: asset)

        let player = AVQueuePlayer()
        let looper = AVPlayerLooper(player: player, templateItem: item)
        return (player, looper)
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

    private static func makeChromaKeyComposition(for asset: AVAsset) -> AVMutableVideoComposition? {
        guard let kernel = chromaKeyKernel else { return nil }
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage.clampedToExtent()
            let output = kernel.apply(extent: request.sourceImage.extent, roiCallback: { _, rect in rect }, arguments: [source])
            request.finish(with: output ?? request.sourceImage, context: nil)
        }
        return composition
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
