//
//  NotchCompanion.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import SwiftUI

/// Where Tuno's notch sits: over the camera notch, or, on a screen without
/// one, a notch-sized space at the top centre of the main screen.
struct NotchGeometry: Equatable {
    /// In global screen coordinates (origin bottom left).
    let rect: CGRect
    /// False for the stand-in on a screen without a camera notch.
    let isHardware: Bool

    init?(notchOf screen: NSScreen) {
        let height = screen.safeAreaInsets.top
        guard height > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        rect = CGRect(x: left.maxX, y: screen.frame.maxY - height, width: right.minX - left.maxX, height: height)
        isHardware = true
    }

    /// A notch the width of a MacBook's, as tall as the menu bar.
    init(standInOn screen: NSScreen) {
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let width: CGFloat = 185
        rect = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - menuBar, width: width, height: menuBar)
        isHardware = false
    }

    /// The built-in display's notch when it's on, else a stand-in on the main screen.
    static var current: NotchGeometry? {
        if let real = NSScreen.screens.lazy.compactMap(NotchGeometry.init(notchOf:)).first { return real }
        return (NSScreen.main ?? NSScreen.screens.first).map(NotchGeometry.init(standInOn:))
    }
}

/// Size and state shared between the controller and the SwiftUI view.
final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var notch = CGSize(width: 180, height: 32)
    /// Whether the expanded player has a progress row (not for live streams).
    @Published var showsProgress = true

    enum Metrics {
        /// Black added beside the notch on each side when closed.
        static let wing: CGFloat = 50
        /// Corner radii. The top corners curve outward into the menu bar,
        /// so the shape grows out of the screen edge like the notch itself.
        static let closedRadii = (top: CGFloat(6), bottom: CGFloat(14))
        static let openRadii = (top: CGFloat(19), bottom: CGFloat(24))
        static let expandedWidth: CGFloat = 360
        static let spacing: CGFloat = 12
        static let bottomPadding: CGFloat = 12
        static let headerHeight: CGFloat = 52
        static let progressHeight: CGFloat = 12
        static let controlsHeight: CGFloat = 28
        /// Room around the open player for its shadow.
        static let shadowMargin: CGFloat = 24
    }

    var radii: (top: CGFloat, bottom: CGFloat) { expanded ? Metrics.openRadii : Metrics.closedRadii }

    /// The black body, not counting the outward top corners.
    var compactSize: CGSize { CGSize(width: notch.width + Metrics.wing * 2, height: notch.height) }

    /// Sized to its content, so there's no slack under the controls.
    var expandedSize: CGSize {
        var body = Metrics.spacing + Metrics.headerHeight + Metrics.spacing + Metrics.controlsHeight + Metrics.bottomPadding
        if showsProgress { body += Metrics.progressHeight + Metrics.spacing }
        // The content starts a little above the notch's bottom edge (see `expanded`).
        return CGSize(width: max(Metrics.expandedWidth, notch.width + 120), height: notch.height - 4 + body)
    }
}

/// The notch player: a black extension of the notch with the artwork and
/// waveform, which opens into a small player on hover or click.
final class NotchController {
    let model = PlayerModel()
    private let state = NotchState()
    private var panel: NotchPanel?
    private var geometry: NotchGeometry?
    private var hoverTimer: Timer?
    private var pendingExpand: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    private var screenObserver: Any?
    private var outsideClickMonitor: Any?

    /// Opened from the keyboard: stays open until the pointer has been in
    /// and out, the shortcut is pressed again, or a click lands elsewhere.
    private var heldOpen = false {
        didSet { watchOutsideClicks(heldOpen) }
    }

    enum Timing {
        /// Hover this long before opening, so sweeping the pointer across
        /// the top of the screen doesn't pop the player open.
        static let openDelay: TimeInterval = 0.3
        static let closeDelay: TimeInterval = 0.1
        /// Opening overshoots a little; closing settles without a bounce.
        static let open = Animation.spring(response: 0.42, dampingFraction: 0.8)
        static let close = Animation.spring(response: 0.45, dampingFraction: 1.0)
        /// How long `close` takes to come to rest, before the window shrinks.
        static let closeSettle: TimeInterval = 0.5
    }

    var isShown: Bool { panel?.isVisible == true }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Shows the notch with the model's current contents.
    func show() {
        guard let geometry = NotchGeometry.current else { return hide() }
        let panel = self.panel ?? makePanel()
        let hasProgress = (model.reading?.duration ?? 0) > 0
        if state.showsProgress != hasProgress {
            state.showsProgress = hasProgress
            if state.expanded { panel.setFrame(frame(expanded: true), display: true) }
        }
        if geometry != self.geometry {
            self.geometry = geometry
            state.notch = geometry.rect.size
            if panel.isVisible { panel.setFrame(frame(expanded: state.expanded), display: true) }
        }
        if !panel.isVisible {
            state.expanded = false
            panel.setFrame(frame(expanded: false), display: true)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        heldOpen = false
        cancelPending()
        watchHover(false)
        state.expanded = false
        panel?.orderOut(nil)
    }

    /// The global shortcut: open the player, or close it if it's open.
    func toggleFromKeyboard() {
        guard isShown else { return NSSound.beep() }
        cancelPending()
        if state.expanded {
            heldOpen = false
            setExpanded(false)
        } else {
            heldOpen = true
            setExpanded(true)
        }
    }

    // MARK: - Opening and closing

    fileprivate func pointerEntered() {
        heldOpen = false
        cancelCollapse()
        guard !state.expanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pointerInside else { return }
            self.setExpanded(true)
        }
        pendingExpand = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.openDelay, execute: work)
    }

    fileprivate func pointerExited() {
        pendingExpand?.cancel()
        scheduleCollapse()
    }

    fileprivate func clicked() {
        pendingExpand?.cancel()
        if !state.expanded { setExpanded(true) }
    }

    private func scheduleCollapse() {
        guard state.expanded, !heldOpen, pendingCollapse == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCollapse = nil
            if !self.pointerInside { self.setExpanded(false) }
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.closeDelay, execute: work)
    }

    private func setExpanded(_ expanded: Bool) {
        guard let panel, state.expanded != expanded else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if expanded {
            // Grow the window first and settle the layout at that size without
            // animation; otherwise the re-centring animates too and the shape
            // flies in from the old window's corner. Then open inside it.
            panel.setFrame(frame(expanded: true), display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in
                withAnimation(reduceMotion ? nil : Timing.open) { self?.state.expanded = true }
            }
            watchHover(true)
        } else {
            watchHover(false)
            withAnimation(reduceMotion ? nil : Timing.close) { state.expanded = false }
            // Shrink the window once the shape has, so the transparent area
            // around it never blocks clicks on the menu bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : Timing.closeSettle)) { [weak self] in
                guard let self, !self.state.expanded else { return }
                panel.setFrame(self.frame(expanded: false), display: true)
            }
        }
    }

    /// Collapses when the pointer has really left, in case an exit event was
    /// missed while the window resized under it.
    private func watchHover(_ on: Bool) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard on else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, !self.pointerInside else { return }
            self.scheduleCollapse()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// While held open from the keyboard, a click anywhere else closes it,
    /// as a click outside a popover would.
    private func watchOutsideClicks(_ on: Bool) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        guard on else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.pointerInside else { return }
            self.heldOpen = false
            self.setExpanded(false)
        }
    }

    private var pointerInside: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    private func cancelPending() {
        pendingExpand?.cancel()
        cancelCollapse()
    }

    /// Cancels a scheduled collapse and forgets it. A cancelled item left in
    /// `pendingCollapse` would block every later collapse from scheduling.
    private func cancelCollapse() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
    }

    // MARK: - Window

    /// Top-centred on the notch, wide enough for the outward top corners.
    /// Open, it includes room for the shadow.
    private func frame(expanded: Bool) -> CGRect {
        guard let notch = geometry?.rect else { return .zero }
        let size: CGSize
        if expanded {
            let margin = NotchState.Metrics.shadowMargin
            let body = state.expandedSize
            size = CGSize(width: body.width + NotchState.Metrics.openRadii.top * 2 + margin * 2,
                          height: body.height + margin)
        } else {
            let body = state.compactSize
            size = CGSize(width: body.width + NotchState.Metrics.closedRadii.top * 2, height: body.height)
        }
        return CGRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height, width: size.width, height: size.height)
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel()
        let container = NotchContainerView()
        container.controller = self
        let hosting = FirstMouseHostingView(rootView: NotchView(model: model, state: state, onTap: { [weak self] in self?.clicked() }))
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        hosting.frame = container.bounds
        self.panel = panel
        return panel
    }

    private func screensChanged() {
        guard isShown else { return }
        guard let geometry = NotchGeometry.current else { return hide() }
        self.geometry = geometry
        state.notch = geometry.rect.size
        panel?.setFrame(frame(expanded: state.expanded), display: true)
    }
}

/// Borderless and non-activating, above the menu bar on every Space.
private final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    /// It sits over the menu bar on purpose; don't push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
}

/// Reports the pointer entering and leaving the whole panel.
private final class NotchContainerView: NSView {
    weak var controller: NotchController?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { controller?.pointerEntered() }
    override func mouseExited(with event: NSEvent) { controller?.pointerExited() }
}

/// Buttons respond to the first click even though Tuno isn't active.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI

/// The notch outline: top corners that curve outward to meet the screen's
/// top edge, and rounded bottom corners. Both radii animate.
private struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { (top, bottom) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(top, rect.width / 4)
        let b = min(bottom, rect.height - t, (rect.width - t * 2) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Outward top-left corner, then down the left side.
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

private struct NotchView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var state: NotchState
    let onTap: () -> Void

    var body: some View {
        let size = state.expanded ? state.expandedSize : state.compactSize
        let radii = state.radii
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if state.expanded {
                    expanded.transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
                } else {
                    compact.transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(.horizontal, radii.top)
            .background(Color.black)
            .clipShape(NotchShape(top: radii.top, bottom: radii.bottom))
            // A black hairline over the top edge hides any seam with the
            // screen edge or the camera notch while the shape morphs.
            .overlay(alignment: .top) {
                Rectangle().fill(Color.black).frame(height: 1).padding(.horizontal, radii.top)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(state.expanded ? 0.6 : 0), radius: 8, y: 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        // There is no menu bar item; this is the way to Settings and Quit.
        .contextMenu {
            Button("Settings…", action: model.onSettings)
            Button("Quit Tuno", action: model.onQuit)
        }
    }

    private var playing: Bool { model.reading?.isPlaying ?? false }
    private var tint: NSColor { playing ? (model.tint ?? .white) : .secondaryLabelColor }

    // MARK: Closed

    private var compact: some View {
        HStack(spacing: 0) {
            artwork(size: 20, radius: 5)
            Spacer(minLength: state.notch.width)
            WaveformView(playing: playing, color: tint)
                .frame(width: 16, height: 14)
        }
        .padding(.horizontal, 12)
        .frame(height: state.notch.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.reading.map { "Now playing: \($0.title)" } ?? "Tuno")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Open

    private var expanded: some View {
        VStack(spacing: NotchState.Metrics.spacing) {
            Color.clear.frame(height: state.notch.height - 4)
            HStack(spacing: 12) {
                Button(action: model.onOpenApp) {
                    HStack(spacing: 12) {
                        artwork(size: NotchState.Metrics.headerHeight, radius: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.reading?.title ?? "Nothing is playing")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            if let subtitle {
                                Text(subtitle)
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(white: 0.63))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.appName.map { "Open \($0)" } ?? "")
                WaveformView(playing: playing, color: tint)
                    .frame(width: 18, height: 16)
            }
            if state.showsProgress, let reading = model.reading {
                NotchProgress(reading: reading)
                    .frame(height: NotchState.Metrics.progressHeight)
            }
            HStack(spacing: 28) {
                control("backward.end.fill", size: 16, label: "Previous") { model.onCommand(.previous) }
                control(playing ? "pause.fill" : "play.fill", size: 20, label: playing ? "Pause" : "Play") {
                    model.onCommand(.playPause)
                }
                control("forward.end.fill", size: 16, label: "Next") { model.onCommand(.next) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, NotchState.Metrics.bottomPadding)
    }

    private var subtitle: String? {
        let parts = [model.reading?.artist, model.appName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Pieces

    private func artwork(size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let image = model.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .saturation(playing ? 1 : 0)
        .opacity(playing ? 1 : 0.55)
    }

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: NotchState.Metrics.controlsHeight, height: NotchState.Metrics.controlsHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Elapsed time, bar and duration on one line. Ticks locally from the last
/// sample, so it moves without new data from the bridge.
private struct NotchProgress: View {
    let reading: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            let position = reading.position(at: context.date) ?? 0
            let duration = reading.duration ?? 0
            HStack(spacing: 8) {
                Text(TimeText.format(position))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white)
                            .frame(width: geometry.size.width * CGFloat(duration > 0 ? position / duration : 0))
                    }
                }
                .frame(height: 4)
                Text(TimeText.format(duration))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(Color(white: 0.63))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(TimeText.format(position)) of \(TimeText.format(duration))")
        }
    }
}
