//
//  CapsuleView.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import QuartzCore

/// The menu bar capsule: artwork, title and a waveform tinted from the
/// artwork. Hovering swaps the waveform for inline playback controls; a long
/// title scrolls in a loop. Optionally shows the artist on a second line and
/// a progress line along the bottom.
///
/// The view never takes clicks itself; StatusItemController routes them with
/// `zone(atScreen:)`.
final class CapsuleView: NSView {
    struct Content: Equatable {
        var title: String
        /// Shown under the title in the two-line display.
        var subtitle: String?
        var isPlaying: Bool
        var artwork: NSImage
        var pausedArtwork: NSImage
        var tint: Tint

        static func == (a: Content, b: Content) -> Bool {
            a.title == b.title && a.subtitle == b.subtitle && a.isPlaying == b.isPlaying && a.artwork === b.artwork
        }
    }

    enum Metrics {
        static let height: CGFloat = 22
        static let artwork: CGFloat = 16
        static let leading: CGFloat = 3
        static let trailing: CGFloat = 8
        static let gap: CGFloat = 6
        static let wave = CGSize(width: 14, height: 12)
        static let control: CGFloat = 20
        static let controlGap: CGFloat = 4
        static var controls: CGFloat { control * 3 + controlGap * 2 }
        /// How long the capsule takes to widen for the controls, and back.
        static let resizeDuration: CFTimeInterval = 0.22
        static let fade: CGFloat = 10
        /// Space between a scrolling title and the copy that follows it.
        static let marqueeGap: CGFloat = 32
        static let marqueeSpeed: CGFloat = 30
        static let marqueeHold: CFTimeInterval = 1.5
        /// Inset of the progress line from the capsule's sides and bottom.
        static let progressInset = CGPoint(x: 9, y: 1.5)
        static let progressHeight: CGFloat = 1.5
    }

    /// Called whenever the capsule's width changes.
    var onResize: (() -> Void)?
    var onControl: ((MediaKeys.Key) -> Void)?

    /// Keeps the capsule expanded with its controls showing, wherever the
    /// pointer is: set while the player popover or the menu is open.
    var isPinned = false {
        didSet {
            guard isPinned != oldValue else { return }
            if isPinned {
                setHovering(true)
            } else if !pointerInside {
                setHovering(false)
            }
        }
    }

    var maxTitleWidth: CGFloat = 150 {
        didSet { if maxTitleWidth != oldValue { restyle() } }
    }

    var display: Preferences.Display = .iconAndTitle {
        didSet { if display != oldValue { restyle() } }
    }

    /// Whether a title too long for the capsule scrolls; otherwise it truncates.
    var scrollsLongTitles = true {
        didSet { if scrollsLongTitles != oldValue { updateMarquee() } }
    }

    var showsProgress = false {
        didSet {
            guard showsProgress != oldValue else { return }
            progressTrack.isHidden = !showsProgress
        }
    }

    private(set) var content: Content?
    private var hovering = false
    /// Index of the inline control under the pointer.
    private var hoveredControl: Int?
    private var marqueeRunning = false
    /// Bumped on every layout, so a finished resize animation can tell
    /// whether a newer layout has replaced it.
    private var layoutGeneration = 0
    private var hoverWatch: Timer?
    private var trackingArea: NSTrackingArea?

    /// Room the status item keeps for the capsule: its hovered width, always.
    /// macOS animates other menu bar items whenever an item's length changes,
    /// which fights any animation of ours, so the length changes only with
    /// the title and hovering grows the capsule inside room already there.
    var reservedWidth: CGFloat { width(hovering: true) }

    private let background = CALayer()
    private let artworkLayer = CALayer()
    private let titleClip = CALayer()
    private let titleLayer = CATextLayer()
    /// Second copy of the title, trailing the first while it scrolls, so the
    /// loop comes back around seamlessly.
    private let titleEcho = CATextLayer()
    private let subtitleLayer = CATextLayer()
    private let fadeMask = CAGradientLayer()
    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    private let waveLayer = WaveformLayer()
    private let controls = NSStackView()
    private let playPauseButton = NSButton()

    private var titleFont: NSFont {
        display == .twoLine
            ? .systemFont(ofSize: 10.5, weight: .semibold)
            : .systemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium)
    }

    private let subtitleFont = NSFont.systemFont(ofSize: 9.5)

    private func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        buildLayers()
        buildControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Content

    func show(_ new: Content) {
        let previous = content
        guard new != previous else { return }
        content = new
        let titleChanged = previous?.title != new.title

        titleLayer.string = new.title
        titleEcho.string = new.title
        subtitleLayer.string = new.subtitle ?? ""
        playPauseButton.image = Self.symbol(new.isPlaying ? "pause.fill" : "play.fill")
        playPauseButton.setAccessibilityLabel(new.isPlaying ? "Pause" : "Play")
        setAccessibilityLabel("Now playing: \(new.title)")

        if titleChanged { stopMarquee() }
        relayout()
        applyColors()
        updateWaveAnimation()
        updateMarquee()
    }

    // MARK: - Layout

    private func measure(_ text: String?, _ font: NSFont) -> CGFloat {
        guard let text, !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Full width of the title in its current font; what the marquee scrolls.
    private var textWidth: CGFloat { measure(content?.title, titleFont) }

    /// Room the text block takes: nothing for the icon display, and the
    /// wider of title and artist for two lines, capped at `maxTitleWidth`.
    private var titleWidth: CGFloat {
        switch display {
        case .icon: return 0
        case .iconAndTitle: return min(textWidth, maxTitleWidth)
        case .twoLine: return min(max(textWidth, measure(content?.subtitle, subtitleFont)), maxTitleWidth)
        }
    }

    /// Width of the visible capsule: hugs the title up to `maxTitleWidth`,
    /// and while hovering grows by the room the controls need, so the title
    /// never gives way to them.
    private func width(hovering: Bool) -> CGFloat {
        let trailing = hovering ? Metrics.controls : Metrics.wave.width
        let text = titleWidth > 0 ? titleWidth + Metrics.gap : 0
        return ceil(Metrics.leading + Metrics.artwork + Metrics.gap + text + trailing + Metrics.trailing)
    }

    /// Re-applies fonts and sizes after a display setting changes.
    private func restyle() {
        stopMarquee()
        relayout()
        updateMarquee()
    }

    /// The visible capsule inside the view. The view always spans
    /// `reservedWidth`; the capsule is pinned to its right edge and grows
    /// left when hovered.
    var capsuleBounds: CGRect {
        let width = width(hovering: hovering)
        return CGRect(x: bounds.width - width, y: 0, width: width, height: Metrics.height)
    }

    private var controlsX: CGFloat { bounds.width - Metrics.trailing - Metrics.controls }

    /// Lays everything out for the current state. With `animated`, the
    /// capsule's edge, artwork and title slide in Core Animation, and the
    /// controls appear once the capsule has widened.
    ///
    /// The view's own frame never changes for a hover. A changing frame makes
    /// AppKit re-snapshot the status item on the CPU (for the menu bar on
    /// other displays) on every frame; moving layers costs one snapshot.
    private func relayout(animated: Bool = false) {
        if frame.width != reservedWidth {
            setFrameSize(NSSize(width: reservedWidth, height: Metrics.height))
            onResize?()
        }
        layoutGeneration += 1
        let generation = layoutGeneration
        let animate = animated && !reduceMotion
        let capsule = capsuleBounds
        let titleLine = lineHeight(titleFont)
        let twoLine = display == .twoLine
        // Two lines share the capsule's full height, title on top.
        let clipHeight = twoLine ? Metrics.height : titleLine
        let titleY = twoLine ? Metrics.height - titleLine : 0

        CATransaction.begin()
        if animate {
            CATransaction.setAnimationDuration(Metrics.resizeDuration)
            // Ease-out cubic: quick to respond, gentle to settle.
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1))
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.controls.isHidden = !self.hovering
            }
        } else {
            CATransaction.setDisableActions(true)
        }
        background.frame = capsule
        artworkLayer.frame = CGRect(x: capsule.minX + Metrics.leading, y: (Metrics.height - Metrics.artwork) / 2,
                                    width: Metrics.artwork, height: Metrics.artwork)
        titleClip.frame = CGRect(x: artworkLayer.frame.maxX + Metrics.gap, y: (Metrics.height - clipHeight) / 2,
                                 width: titleWidth, height: clipHeight)
        // Two lines of text leave no room above the capsule's bottom edge, so
        // the line sits lower and thinner there.
        let progressY = twoLine ? 0.5 : Metrics.progressInset.y
        let progressHeight = twoLine ? 1 : Metrics.progressHeight
        progressTrack.frame = CGRect(x: capsule.minX + Metrics.progressInset.x, y: progressY,
                                     width: capsule.width - Metrics.progressInset.x * 2, height: progressHeight)
        progressTrack.cornerRadius = progressHeight / 2
        progressFill.frame = progressTrack.bounds
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleClip.isHidden = display == .icon
        if !marqueeRunning {
            titleLayer.frame = CGRect(x: 0, y: titleY, width: titleWidth, height: titleLine)
        }
        for layer in [titleLayer, titleEcho] {
            layer.font = titleFont
            layer.fontSize = titleFont.pointSize
        }
        subtitleLayer.isHidden = !twoLine
        subtitleLayer.font = subtitleFont
        subtitleLayer.fontSize = subtitleFont.pointSize
        subtitleLayer.frame = CGRect(x: 0, y: 0, width: titleWidth, height: lineHeight(subtitleFont))
        waveLayer.frame = CGRect(x: bounds.width - Metrics.trailing - Metrics.wave.width,
                                 y: (Metrics.height - Metrics.wave.height) / 2,
                                 width: Metrics.wave.width, height: Metrics.wave.height)
        waveLayer.isHidden = hovering
        CATransaction.commit()

        controls.frame = CGRect(x: controlsX, y: (Metrics.height - Metrics.control) / 2,
                                width: Metrics.controls, height: Metrics.control)
        if !animate { controls.isHidden = !hovering }
        updateTracking()
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [background, artworkLayer, titleClip, titleLayer, titleEcho, subtitleLayer, waveLayer, progressTrack, progressFill]
            .forEach { $0.contentsScale = scale }
    }

    private func applyColors() {
        guard let content else { return }
        let dark = isDark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let chip = dark ? NSColor.white : NSColor.black
            background.backgroundColor = chip.withAlphaComponent(hovering ? (dark ? 0.20 : 0.12) : (dark ? 0.10 : 0.06)).cgColor
            background.borderColor = chip.withAlphaComponent(dark ? 0.08 : 0.06).cgColor
            titleLayer.foregroundColor = (content.isPlaying ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor
            titleEcho.foregroundColor = titleLayer.foregroundColor
            subtitleLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
            let barColor = content.isPlaying ? content.tint.color(onDark: dark) : NSColor.secondaryLabelColor
            waveLayer.color = barColor.cgColor
            progressTrack.backgroundColor = chip.withAlphaComponent(dark ? 0.16 : 0.10).cgColor
            progressFill.backgroundColor = barColor.cgColor
            for (index, view) in controls.arrangedSubviews.enumerated() {
                // The control under the pointer turns white; the rest keep the usual colour.
                // Resolved here rather than left dynamic: buttons in the status bar
                // resolve dynamic colours against a light appearance even on a dark bar.
                let rest = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
                (view as? NSButton)?.contentTintColor = hoveredControl == index ? .white : rest
            }
        }
        artworkLayer.contents = content.isPlaying ? content.artwork : content.pausedArtwork
        artworkLayer.opacity = content.isPlaying ? 1 : 0.55
        CATransaction.commit()
    }

    // MARK: - Waveform

    private func updateWaveAnimation() {
        waveLayer.update(playing: content?.isPlaying ?? false, animated: !reduceMotion)
    }

    // MARK: - Progress

    /// Sets the progress line from a playback sample. While playing, Core
    /// Animation runs it to the end on its own, so it needs no ticks from here;
    /// the next sample (seek, pause, track change) simply replaces it.
    func setProgress(_ fraction: Double?, remaining: TimeInterval?, rate: Double, playing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressFill.removeAnimation(forKey: "progress")
        let start = CGFloat(min(max(fraction ?? 0, 0), 1))
        progressFill.transform = CATransform3DMakeScale(start, 1, 1)
        progressTrack.isHidden = !showsProgress || fraction == nil
        CATransaction.commit()

        guard playing, rate > 0, let remaining, remaining > 0 else { return }
        let run = CABasicAnimation(keyPath: "transform.scale.x")
        run.fromValue = start
        run.toValue = 1
        run.duration = remaining / rate
        run.timingFunction = CAMediaTimingFunction(name: .linear)
        run.fillMode = .forwards
        run.isRemovedOnCompletion = false
        progressFill.add(run, forKey: "progress")
    }

    // MARK: - Marquee

    /// A title too long for the capsule scrolls in a loop while playing:
    /// it rests at the start, slides out to the left as its copy slides in,
    /// and rests again. Hovering, pausing or Reduce Motion show it truncated.
    private func updateMarquee() {
        let overflows = textWidth > titleClip.bounds.width + 1
        let wanted = overflows && scrollsLongTitles && display != .icon && !hovering
            && content?.isPlaying == true && !reduceMotion
        if wanted, !marqueeRunning {
            startMarquee()
        } else if !wanted, marqueeRunning {
            stopMarquee()
        }
    }

    private func startMarquee() {
        marqueeRunning = true
        let visible = titleClip.bounds.width
        let line = titleLayer.frame
        let distance = textWidth + Metrics.marqueeGap

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.frame = CGRect(x: 0, y: line.minY, width: textWidth, height: line.height)
        titleEcho.frame = CGRect(x: distance, y: 0, width: textWidth, height: line.height)
        titleEcho.isHidden = false
        fadeMask.frame = titleClip.bounds
        titleClip.mask = fadeMask
        CATransaction.commit()

        let scroll = CFTimeInterval(distance / Metrics.marqueeSpeed)
        let cycle = Metrics.marqueeHold + scroll
        let holdEnd = NSNumber(value: Metrics.marqueeHold / cycle)

        let slide = CAKeyframeAnimation(keyPath: "transform.translation.x")
        slide.values = [0, 0, -distance]
        slide.keyTimes = [0, holdEnd, 1]
        slide.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        slide.duration = cycle
        slide.repeatCount = .infinity
        titleLayer.add(slide, forKey: "marquee")

        // No fade on the leading edge while resting, so the first letters
        // read cleanly; both edges fade while the title moves.
        let edge = Double(Metrics.fade / max(visible, 1))
        let resting: [NSNumber] = [0, 0, NSNumber(value: 1 - edge), 1]
        let moving: [NSNumber] = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        let blend = 0.15 / cycle
        let fade = CAKeyframeAnimation(keyPath: "locations")
        fade.values = [resting, resting, moving, moving, resting]
        fade.keyTimes = [0, holdEnd, NSNumber(value: holdEnd.doubleValue + blend), NSNumber(value: 1 - blend), 1]
        fade.duration = cycle
        fade.repeatCount = .infinity
        fadeMask.locations = resting
        fadeMask.add(fade, forKey: "marquee")
    }

    private func stopMarquee() {
        guard marqueeRunning else { return }
        marqueeRunning = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.removeAnimation(forKey: "marquee")
        fadeMask.removeAnimation(forKey: "marquee")
        titleEcho.isHidden = true
        titleClip.mask = nil
        CATransaction.commit()
        relayout()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTracking()
    }

    /// Tracks the visible capsule only, not the room reserved beside it.
    private func updateTracking() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        // The status bar window is never key, so track regardless of activation.
        let area = NSTrackingArea(rect: capsuleBounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }

    /// The capsule moves under a still pointer while it resizes, and AppKit
    /// reports that as an exit. Only leave hover once the pointer really is
    /// outside; `hoverWatch` catches the exits this lets through.
    override func mouseExited(with event: NSEvent) {
        if !pointerInside { setHovering(false) }
    }

    private var pointerInside: Bool {
        screenFrame?.contains(NSEvent.mouseLocation) ?? false
    }

    private func watchHover(_ on: Bool) {
        hoverWatch?.invalidate()
        hoverWatch = nil
        guard on else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, !self.pointerInside else { return }
            self.setHovering(false)
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverWatch = timer
    }

    override func mouseMoved(with event: NSEvent) {
        var index: Int?
        if case .control(let key) = zone(atScreen: NSEvent.mouseLocation) {
            index = [MediaKeys.Key.previous, .playPause, .next].firstIndex(of: key)
        }
        guard index != hoveredControl else { return }
        hoveredControl = index
        applyColors()
    }

    private func setHovering(_ value: Bool) {
        guard hovering != value, content != nil, value || !isPinned else { return }
        // Before the flag flips, so the stopped marquee's relayout keeps the old width.
        stopMarquee()
        hovering = value
        watchHover(value)
        if !value { hoveredControl = nil }
        // Controls show only once the capsule has widened, and go before it narrows.
        if !value { controls.isHidden = true }
        relayout(animated: true)
        applyColors()
        updateMarquee()
    }

    /// The status bar button takes every click itself, whatever the views
    /// inside it say, so the capsule never claims one. Clicks are routed by
    /// `zone(atScreen:)` instead.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    enum Zone: Equatable {
        /// Artwork and title: opens the menu.
        case title
        case control(MediaKeys.Key)
        /// Padding and the gaps between controls: does nothing.
        case none
    }

    /// The visible capsule's frame in screen coordinates.
    var screenFrame: NSRect? {
        guard let window, !isHidden else { return nil }
        return window.convertToScreen(convert(capsuleBounds, to: nil))
    }

    /// What a click at `screenPoint` lands on. Works from the screen position
    /// and the capsule's own layout, because the status bar's mouse events
    /// don't carry coordinates relative to this view's window.
    func zone(atScreen screenPoint: NSPoint) -> Zone {
        guard let window else { return .none }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard point.x >= capsuleBounds.minX, point.x < bounds.width else { return .none }
        if point.x < titleClip.frame.maxX + Metrics.gap / 2 { return .title }
        guard !controls.isHidden else { return .none }

        let offset = point.x - controlsX
        let slot = Metrics.control + Metrics.controlGap
        let index = Int(offset / slot)
        guard offset >= 0, index < 3, offset - CGFloat(index) * slot < Metrics.control else { return .none }
        return .control([.previous, .playPause, .next][index])
    }

    // MARK: - Construction

    private func buildLayers() {
        guard let root = layer else { return }
        background.cornerRadius = Metrics.height / 2
        background.borderWidth = 0.5
        root.addSublayer(background)

        artworkLayer.cornerRadius = 4
        artworkLayer.masksToBounds = true
        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.borderWidth = 0.5
        artworkLayer.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        root.addSublayer(artworkLayer)

        titleClip.masksToBounds = true
        titleLayer.truncationMode = .end
        titleLayer.isWrapped = false
        titleLayer.alignmentMode = .left
        // Text re-renders when the title, its width or the marquee changes;
        // the default 0.25 s crossfade would show old and new text overlapping.
        let still: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        titleLayer.actions = still
        titleEcho.actions = still
        titleEcho.isWrapped = false
        titleEcho.alignmentMode = .left
        titleEcho.isHidden = true
        titleLayer.addSublayer(titleEcho)
        titleClip.addSublayer(titleLayer)
        subtitleLayer.truncationMode = .end
        subtitleLayer.isWrapped = false
        subtitleLayer.alignmentMode = .left
        subtitleLayer.actions = still
        subtitleLayer.isHidden = true
        titleClip.addSublayer(subtitleLayer)
        root.addSublayer(titleClip)

        progressTrack.cornerRadius = Metrics.progressHeight / 2
        progressTrack.masksToBounds = true
        progressTrack.isHidden = true
        progressFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressTrack.addSublayer(progressFill)
        root.addSublayer(progressTrack)

        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]

        root.addSublayer(waveLayer)
    }

    private func buildControls() {
        // Display only: clicks never reach these buttons (see `zone(atScreen:)`),
        // but their actions keep them usable from VoiceOver.
        let previous = Self.controlButton("backward.end.fill", label: "Previous", action: #selector(previousTapped))
        playPauseButton.action = #selector(playPauseTapped)
        Self.styleControl(playPauseButton, symbol: "pause.fill", label: "Pause")
        let next = Self.controlButton("forward.end.fill", label: "Next", action: #selector(nextTapped))
        [previous, playPauseButton, next].forEach { $0.target = self }

        controls.orientation = .horizontal
        controls.spacing = Metrics.controlGap
        controls.distribution = .fillEqually
        controls.setViews([previous, playPauseButton, next], in: .leading)
        controls.isHidden = true
        addSubview(controls)
    }

    private static func controlButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.action = action
        styleControl(button, symbol: symbol, label: label)
        return button
    }

    private static func styleControl(_ button: NSButton, symbol: String, label: String) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.image = Self.symbol(symbol)
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: Metrics.control).isActive = true
        button.heightAnchor.constraint(equalToConstant: Metrics.control).isActive = true
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    }

    @objc private func previousTapped() { onControl?(.previous) }
    @objc private func playPauseTapped() { onControl?(.playPause) }
    @objc private func nextTapped() { onControl?(.next) }
}
