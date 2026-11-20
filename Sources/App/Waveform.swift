//
//  Waveform.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import QuartzCore
import SwiftUI

/// Four bars that bounce while playing and lie flat when paused. The motion
/// is a Core Animation loop, so it costs nothing on the main thread.
final class WaveformLayer: CALayer {
    /// The design's 14 × 12 pt drawing; other sizes scale from it.
    static let designSize = CGSize(width: 14, height: 12)

    /// Per-bar period and offset, so the bars never move in lockstep.
    private static let timing: [(period: CFTimeInterval, delay: CFTimeInterval)] =
        [(0.95, 0), (0.75, 0.2), (1.15, 0.1), (0.85, 0.35)]

    private let bars = (0..<4).map { _ in CALayer() }
    private var playing = false
    private var animated = false

    var color: CGColor? {
        didSet { bars.forEach { $0.backgroundColor = color } }
    }

    override init() {
        super.init()
        bars.forEach { addSublayer($0) }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var contentsScale: CGFloat {
        didSet { bars.forEach { $0.contentsScale = contentsScale } }
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        update(playing: playing, animated: animated)
    }

    func update(playing: Bool, animated: Bool) {
        self.playing = playing
        self.animated = animated
        let sx = bounds.width / Self.designSize.width
        let sy = bounds.height / Self.designSize.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let x = (0.5 + CGFloat(index) * 3.7) * sx
            bar.cornerRadius = sx
            // Full-height bars scaled down while playing; short flat bars when paused.
            bar.frame = playing
                ? CGRect(x: x, y: 1 * sy, width: 2 * sx, height: 10 * sy)
                : CGRect(x: x, y: 4.5 * sy, width: 2 * sx, height: 3 * sy)
            bar.removeAnimation(forKey: "level")
            bar.transform = CATransform3DIdentity
            guard playing, animated else {
                if playing { bar.transform = CATransform3DMakeScale(1, 0.6, 1) }
                continue
            }
            let timing = Self.timing[index]
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
}

/// `WaveformLayer` for SwiftUI.
struct WaveformView: NSViewRepresentable {
    var playing: Bool
    var color: NSColor

    func makeNSView(context: Context) -> WaveformHostView { WaveformHostView() }

    func updateNSView(_ view: WaveformHostView, context: Context) {
        view.wave.color = color.cgColor
        view.wave.update(playing: playing, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

final class WaveformHostView: NSView {
    let wave = WaveformLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(wave)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wave.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        wave.contentsScale = window?.backingScaleFactor ?? 2
    }
}
