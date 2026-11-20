//
//  CapsuleView.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import QuartzCore

/// The menu bar capsule: artwork, title and a waveform tinted from the
/// artwork. Hovering swaps the waveform for inline playback controls; a
/// track change scrolls a long title once before it truncates.
///
/// Clicks outside the inline controls fall through to the status item button,
/// so the button keeps its own highlight and menu handling.
final class CapsuleView: NSView {
    struct Content: Equatable {
        var title: String
        var isPlaying: Bool
        var artwork: NSImage
        var pausedArtwork: NSImage
        var tint: Tint

        static func == (a: Content, b: Content) -> Bool {
            a.title == b.title && a.isPlaying == b.isPlaying && a.artwork === b.artwork
        }
    }

    enum Metrics {
        static let height: CGFloat = 22
        static let artwork: CGFloat = 16
        static let leading: CGFloat = 3
        static let trailing: CGFloat = 8
        static let gap: CGFloat = 6
        static let wave = CGSize(width: 14, height: 12)
        static let control: CGFloat = 18
        static let controlGap: CGFloat = 2
        static var controls: CGFloat { control * 3 + controlGap * 2 }
        /// Title width kept visible next to the controls while hovering.
        static let minHoverTitle: CGFloat = 40
        static let fade: CGFloat = 10
    }

    /// Called with the capsule's new width whenever it changes.
    var onResize: ((CGFloat) -> Void)?
    var onControl: ((MediaKeys.Key) -> Void)?

    var maxTitleWidth: CGFloat = 180 {
        didSet { if maxTitleWidth != oldValue { relayout() } }
    }

    private(set) var content: Content?
    private var hovering = false
    private var marqueeToken = 0
    private var marqueeRunning = false

    private let background = CALayer()
    private let artworkLayer = CALayer()
    private let titleClip = CALayer()
    private let titleLayer = CATextLayer()
    private let fadeMask = CAGradientLayer()
    private let waveLayer = CALayer()
    private let bars = (0..<4).map { _ in CALayer() }
    private let controls = NSStackView()
    private let playPauseButton = NSButton()

    private var titleFont: NSFont {
        .systemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium)
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
        let trackChanged = previous != nil && previous?.title != new.title

        titleLayer.string = new.title
        playPauseButton.image = Self.symbol(new.isPlaying ? "pause.fill" : "play.fill")
        playPauseButton.setAccessibilityLabel(new.isPlaying ? "Pause" : "Play")
        setAccessibilityLabel("Now playing: \(new.title)")

        if trackChanged { cancelMarquee() }
        relayout()
        applyColors()
        updateWaveAnimation()
        if trackChanged { startMarqueeIfNeeded() }
    }

    // MARK: - Layout

    private var textWidth: CGFloat {
        guard let title = content?.title else { return 0 }
        return ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
    }

    /// Width with the waveform showing.
    private var restingWidth: CGFloat {
        Metrics.leading + Metrics.artwork + Metrics.gap + min(textWidth, maxTitleWidth)
            + Metrics.gap + Metrics.wave.width + Metrics.trailing
    }

    /// Hover keeps the resting width when the controls fit, so other menu bar
    /// items don't shift; it only grows for very short titles.
    private var hoverWidth: CGFloat {
        let needed = Metrics.leading + Metrics.artwork + Metrics.gap + min(textWidth, Metrics.minHoverTitle)
            + Metrics.gap + Metrics.controls + Metrics.gap
        return max(restingWidth, needed)
    }

    var preferredWidth: CGFloat { ceil(hovering ? hoverWidth : restingWidth) }

    private func relayout() {
        let width = preferredWidth
        if frame.width != width {
            setFrameSize(NSSize(width: width, height: Metrics.height))
            onResize?(width)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        artworkLayer.frame = CGRect(x: Metrics.leading, y: (Metrics.height - Metrics.artwork) / 2,
                                    width: Metrics.artwork, height: Metrics.artwork)

        let titleX = artworkLayer.frame.maxX + Metrics.gap
        let trailingStart = hovering
            ? width - Metrics.gap - Metrics.controls
            : width - Metrics.trailing - Metrics.wave.width
        let visible = max(0, trailingStart - Metrics.gap - titleX)
        let lineHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
        titleClip.frame = CGRect(x: titleX, y: (Metrics.height - lineHeight) / 2, width: visible, height: lineHeight)
        if !marqueeRunning {
            titleLayer.frame = CGRect(x: 0, y: 0, width: visible, height: lineHeight)
        }
        titleLayer.font = titleFont
        titleLayer.fontSize = titleFont.pointSize

        waveLayer.frame = CGRect(x: width - Metrics.trailing - Metrics.wave.width,
                                 y: (Metrics.height - Metrics.wave.height) / 2,
                                 width: Metrics.wave.width, height: Metrics.wave.height)
        waveLayer.isHidden = hovering
        CATransaction.commit()

        controls.frame = CGRect(x: width - Metrics.gap - Metrics.controls, y: (Metrics.height - Metrics.control) / 2,
                                width: Metrics.controls, height: Metrics.control)
        controls.isHidden = !hovering
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [background, artworkLayer, titleClip, titleLayer, waveLayer].forEach { $0.contentsScale = scale }
        bars.forEach { $0.contentsScale = scale }
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
            let barColor = content.isPlaying ? content.tint.color(onDark: dark) : NSColor.secondaryLabelColor
            bars.forEach { $0.backgroundColor = barColor.cgColor }
            controls.arrangedSubviews.forEach { ($0 as? NSButton)?.contentTintColor = .labelColor }
        }
        artworkLayer.contents = content.isPlaying ? content.artwork : content.pausedArtwork
        artworkLayer.opacity = content.isPlaying ? 1 : 0.55
        CATransaction.commit()
    }

    // MARK: - Waveform

    /// Per-bar period and offset, so the bars never move in lockstep.
    private static let barTiming: [(period: CFTimeInterval, delay: CFTimeInterval)] =
        [(0.95, 0), (0.75, 0.2), (1.15, 0.1), (0.85, 0.35)]

    private func updateWaveAnimation() {
        let playing = content?.isPlaying ?? false
        let animate = playing && !reduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let x = 0.5 + CGFloat(index) * 3.7
            // Full-height bars scaled down while playing; short flat bars when paused.
            bar.frame = playing ? CGRect(x: x, y: 1, width: 2, height: 10) : CGRect(x: x, y: 4.5, width: 2, height: 3)
            bar.removeAnimation(forKey: "level")
            bar.transform = CATransform3DIdentity
            guard animate else {
                if playing { bar.transform = CATransform3DMakeScale(1, 0.6, 1) }
                continue
            }
            let timing = Self.barTiming[index]
            let level = CABasicAnimation(keyPath: "transform.scale.y")
            level.fromValue = 0.3
            level.toValue = 1
            level.duration = timing.period / 2
            level.autoreverses = true
            level.repeatCount = .infinity
            level.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            level.beginTime = CACurrentMediaTime() + timing.delay
            level.fillMode = .backwards
            bar.add(level, forKey: "level")
        }
        CATransaction.commit()
    }

    // MARK: - Marquee

    /// Scroll an overflowing title once, then settle into a truncated title.
    private func startMarqueeIfNeeded() {
        let visible = titleClip.bounds.width
        let overflow = textWidth - visible
        guard overflow > 1, !reduceMotion else { return }

        marqueeToken += 1
        let token = marqueeToken
        marqueeRunning = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.frame.size.width = textWidth + Metrics.fade
        titleClip.mask = fadeMask
        fadeMask.frame = titleClip.bounds
        let edge = NSNumber(value: Double(Metrics.fade / max(visible, 1)))
        fadeMask.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
        CATransaction.commit()

        let distance = overflow + Metrics.fade
        let scroll = CABasicAnimation(keyPath: "transform.translation.x")
        scroll.fromValue = 0
        scroll.toValue = -distance
        scroll.beginTime = CACurrentMediaTime() + 0.8
        scroll.duration = Double(distance) / 30
        scroll.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scroll.fillMode = .both
        scroll.isRemovedOnCompletion = false
        titleLayer.add(scroll, forKey: "marquee")

        // Hold on the end of the title for a moment before snapping back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + scroll.duration + 1.2) { [weak self] in
            guard let self, self.marqueeToken == token else { return }
            self.cancelMarquee()
        }
    }

    private func cancelMarquee() {
        guard marqueeRunning else { return }
        marqueeToken += 1
        marqueeRunning = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.removeAnimation(forKey: "marquee")
        titleClip.mask = nil
        CATransaction.commit()
        relayout()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // The status bar window is never key, so track regardless of activation.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        guard hovering != value, content != nil else { return }
        hovering = value
        cancelMarquee()
        relayout()
        applyColors()
    }

    /// Only the inline controls take clicks; everything else reaches the
    /// status item button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hovering, !controls.isHidden else { return nil }
        let local = convert(point, from: superview)
        return controls.frame.contains(local) ? super.hitTest(point) : nil
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
        titleClip.addSublayer(titleLayer)
        root.addSublayer(titleClip)

        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]

        bars.forEach {
            $0.cornerRadius = 1
            waveLayer.addSublayer($0)
        }
        root.addSublayer(waveLayer)
    }

    private func buildControls() {
        let previous = Self.controlButton("backward.end.fill", label: "Previous", action: #selector(previousTapped))
        playPauseButton.target = self
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
