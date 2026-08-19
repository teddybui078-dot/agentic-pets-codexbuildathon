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
        ("Small", 180), ("Medium", 260), ("Large", 340)
    ]

    /// Fraction from the top of the square to the top of the character's head —
    /// shared with PetWindowController so the speech bubble can anchor right above it.
    static let headTopFraction: CGFloat = 0.10

    /// Where the character actually sits within the square video frame (measured via
    /// ffmpeg cropdetect against the near-white background, then padded generously for
    /// animation motion and a forgiving hit target), as fractions of the view's bounds.
    /// Both hover detection and mouse hit-testing are scoped to this region: outside
    /// it, the view is click-through so the transparent margin doesn't swallow clicks/
    /// hover meant for whatever's behind the pet.
    private static let characterRegionFraction = (minX: 0.14, maxX: 0.83, minYFromTop: headTopFraction, maxYFromTop: 0.92)

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

    /// Makes the transparent margin around the character click-through: outside
    /// `characterHitRegion`, this view isn't hit, so clicks/hover/scroll fall through
    /// to whatever's behind the pet instead of being swallowed by empty video padding.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let localPoint = convert(point, from: superview)
        return characterHitRegion.contains(localPoint) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        guard isHoverAvailable else { return }
        setHoverLayerVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isHoverAvailable else { return }
        setHoverLayerVisible(false)
    }

    /// Toggling `isHidden` on a layer-backed view implicitly animates (fades) by
    /// default, which is what made the hover swap feel laggy. Disable that so it's
    /// an instant cut.
    private func setHoverLayerVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        idleLayer.isHidden = visible
        hoverLayer.isHidden = !visible
        CATransaction.commit()
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

/// Speech-bubble / mini chat panel content view used by PetWindowController. Shows
/// a wrapped status/nudge message, a close button (it otherwise stays up until
/// dismissed — no auto-hide timer), and a text field to ask the pet a question.
final class PetBubbleView: NSView {

    static let width: CGFloat = 240
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 10
    private static let minHeight: CGFloat = 44
    private static let inputHeight: CGFloat = 24
    private static let inputSpacing: CGFloat = 8
    private static let closeButtonSize: CGFloat = 16

    /// Fired when the user clicks the close button.
    var onClose: (() -> Void)?
    /// Fired with the typed question when the user presses Return in the input field.
    var onAsk: ((String) -> Void)?

    private let label: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        field.textColor = .labelColor
        field.backgroundColor = .clear
        field.isBezeled = false
        field.isEditable = false
        field.alignment = .center
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.translatesAutoresizingMaskIntoConstraints = false
        field.preferredMaxLayoutWidth = PetBubbleView.width - PetBubbleView.horizontalPadding * 2
        return field
    }()

    private let closeButton: NSButton = {
        let button = NSButton(title: "✕", target: nil, action: nil)
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let inputField: NSTextField = {
        let field = NSTextField()
        field.placeholderString = "Ask about your agents…"
        field.font = NSFont.systemFont(ofSize: 11)
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

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        inputField.target = self
        inputField.action = #selector(askSubmitted)

        addSubview(label)
        addSubview(closeButton)
        addSubview(inputField)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: Self.closeButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Self.closeButtonSize),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding + 10),

            inputField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            inputField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            inputField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Self.inputSpacing),
            inputField.heightAnchor.constraint(equalToConstant: Self.inputHeight),
            inputField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        label.stringValue = text
    }

    /// Gives the input field keyboard focus so the user can start typing immediately.
    func focusInput() {
        inputField.window?.makeFirstResponder(inputField)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func askSubmitted() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""
        onAsk?(text)
    }

    /// The bubble size needed to show the current text fully wrapped, no clipping,
    /// plus room for the input row. `intrinsicContentSize` is what Auto Layout itself
    /// uses to size a wrapping label against `preferredMaxLayoutWidth`.
    func fittingSize() -> NSSize {
        let labelHeight = label.intrinsicContentSize.height
        let height = Self.verticalPadding + 10 + labelHeight + Self.inputSpacing + Self.inputHeight + Self.verticalPadding
        return NSSize(width: Self.width, height: max(height, Self.minHeight))
    }
}
