//
//  ProgressLine.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import QuartzCore
import SwiftUI

/// A thin progress bar that fills on its own: one Core Animation runs from
/// the current position to the end of the track, so nothing redraws while
/// it plays. Like `WaveformLayer`, it costs nothing on the main thread.
final class ProgressLineLayer: CALayer {
    private let fill = CALayer()
    private(set) var reading: NowPlaying?

    var color: CGColor? {
        didSet { fill.backgroundColor = color }
    }

    override init() {
        super.init()
        backgroundColor = CGColor(gray: 1, alpha: 0.2)
        masksToBounds = true
        // Grows from the left edge.
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        addSublayer(fill)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        update(reading: reading)
    }

    /// Shows `reading`'s position now and, if it's playing, sets the bar
    /// running to the end at the player's rate.
    func update(reading: NowPlaying?) {
        self.reading = reading
        let size = bounds.size
        let now = Date()
        // A live stream has no progress to show; the line is just lit.
        let fraction = CGFloat(reading?.progress(at: now) ?? 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cornerRadius = size.height / 2
        fill.cornerRadius = size.height / 2
        fill.position = CGPoint(x: 0, y: size.height / 2)
        fill.bounds = CGRect(x: 0, y: 0, width: size.width * fraction, height: size.height)
        fill.removeAnimation(forKey: "progress")
        if let reading, reading.isPlaying, reading.rate > 0, let duration = reading.duration, duration > 0,
           let position = reading.position(at: now), position < duration, size.width > 0 {
            let run = CABasicAnimation(keyPath: "bounds.size.width")
            run.fromValue = size.width * fraction
            run.toValue = size.width
            run.duration = (duration - position) / reading.rate
            run.timingFunction = CAMediaTimingFunction(name: .linear)
            // Stays full at the end until the next reading says otherwise.
            run.fillMode = .forwards
            run.isRemovedOnCompletion = false
            fill.add(run, forKey: "progress")
        }
        CATransaction.commit()
    }
}

/// Playback progress as a thin line under the notch, for when the menu bar
/// leaves no room for the wings.
struct ProgressLine: NSViewRepresentable {
    @ObservedObject var model: PlayerModel

    func makeNSView(context: Context) -> ProgressLineHostView { ProgressLineHostView() }

    func updateNSView(_ view: ProgressLineHostView, context: Context) {
        view.line.color = model.activeTint.cgColor
        view.line.update(reading: model.reading)
    }
}

final class ProgressLineHostView: NSView {
    let line = ProgressLineLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(line)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = bounds
        CATransaction.commit()
    }

    /// Core Animation drops a layer's animations while it is off screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { line.update(reading: line.reading) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        line.contentsScale = window?.backingScaleFactor ?? 2
    }
}
