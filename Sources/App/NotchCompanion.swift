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
    /// Briefly showing a new track's title under the closed notch.
    @Published var peeking = false
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
        /// Line added under the closed notch for a sneak peek.
        static let peekLine: CGFloat = 22
    }

    var radii: (top: CGFloat, bottom: CGFloat) { expanded ? Metrics.openRadii : Metrics.closedRadii }

    /// The black body, not counting the outward top corners.
    var compactSize: CGSize { CGSize(width: notch.width + Metrics.wing * 2, height: notch.height) }

    var peekSize: CGSize { CGSize(width: compactSize.width, height: notch.height + Metrics.peekLine) }

    /// The body's size in the current state.
    var bodySize: CGSize { expanded ? expandedSize : peeking ? peekSize : compactSize }

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
    /// Called when the player opens, to refresh what it shows.
    var onExpand: (() -> Void)?
    private let state = NotchState()
    private var peekEnd: DispatchWorkItem?
    /// Accumulated trackpad travel in the current two-finger gesture, in
    /// finger direction (down and right are positive).
    private var gestureTravel = CGPoint.zero
    private var gestureHandled = false
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
        /// How long a sneak peek stays up.
        static let peek: TimeInterval = 2.8
    }

    var isShown: Bool { panel?.isVisible == true }
    var isExpanded: Bool { state.expanded }

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
            if state.expanded { panel.setFrame(currentFrame, display: true) }
        }
        if geometry != self.geometry {
            self.geometry = geometry
            state.notch = geometry.rect.size
            if panel.isVisible { panel.setFrame(currentFrame, display: true) }
        }
        if !panel.isVisible {
            state.expanded = false
            state.peeking = false
            panel.setFrame(currentFrame, display: true)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        heldOpen = false
        cancelPending()
        peekEnd?.cancel()
        watchHover(false)
        state.expanded = false
        state.peeking = false
        panel?.orderOut(nil)
    }

    /// Shows a new track's title under the closed notch for a moment.
    func peek() {
        guard let panel, panel.isVisible, !state.expanded else { return }
        peekEnd?.cancel()
        if !state.peeking {
            // As when opening: grow the window, settle the layout, then animate.
            state.peeking = true
            let target = currentFrame
            state.peeking = false
            panel.setFrame(target, display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in
                withAnimation(Self.animation(Timing.open)) { self?.state.peeking = true }
            }
        }
        let end = DispatchWorkItem { [weak self] in self?.endPeek() }
        peekEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.peek, execute: end)
    }

    private func endPeek() {
        guard state.peeking, !state.expanded else { return }
        withAnimation(Self.animation(Timing.close)) { state.peeking = false }
        shrinkWindowWhenSettled()
    }

    private static func animation(_ animation: Animation) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
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

    /// Two-finger swipes on the notch: down opens, up closes, left and
    /// right skip tracks. One action per gesture; momentum is ignored.
    fileprivate func scrolled(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase == .began {
            gestureTravel = .zero
            gestureHandled = false
        }
        // In finger direction, whichever way scrolling is set to run.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        gestureTravel.x += event.scrollingDeltaX * sign
        gestureTravel.y += event.scrollingDeltaY * sign
        defer {
            if event.phase == .ended || event.phase == .cancelled { gestureHandled = false }
        }
        guard !gestureHandled else { return }

        let (x, y) = (gestureTravel.x, gestureTravel.y)
        if abs(y) > abs(x), y > 30, !state.expanded {
            gestureHandled = true
            clicked()
        } else if abs(y) > abs(x), y < -30, state.expanded {
            gestureHandled = true
            heldOpen = false
            setExpanded(false)
        } else if abs(x) > 50, abs(x) > abs(y) * 1.5 {
            gestureHandled = true
            Self.haptic()
            model.onCommand(x < 0 ? .next : .previous)
        }
    }

    private static func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
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
        if expanded {
            peekEnd?.cancel()
            // Grow the window first and settle the layout at that size without
            // animation; otherwise the re-centring animates too and the shape
            // flies in from the old window's corner. Then open inside it.
            panel.setFrame(frame(forExpanded: true), display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in
                withAnimation(Self.animation(Timing.open)) {
                    self?.state.expanded = true
                    self?.state.peeking = false
                }
            }
            Self.haptic()
            watchHover(true)
            onExpand?()
        } else {
            watchHover(false)
            withAnimation(Self.animation(Timing.close)) { state.expanded = false }
            shrinkWindowWhenSettled()
        }
    }

    /// Shrinks the window once the shape has, so the transparent area around
    /// it never blocks clicks on the menu bar.
    private func shrinkWindowWhenSettled() {
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Timing.closeSettle
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let panel = self.panel, !self.state.expanded, !self.state.peeking else { return }
            panel.setFrame(self.currentFrame, display: true)
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

    private var currentFrame: CGRect { frame(forExpanded: state.expanded) }

    /// Top-centred on the notch, wide enough for the outward top corners.
    /// Open, it includes room for the shadow.
    private func frame(forExpanded expanded: Bool) -> CGRect {
        guard let notch = geometry?.rect else { return .zero }
        let size: CGSize
        if expanded {
            let margin = NotchState.Metrics.shadowMargin
            let body = state.expandedSize
            size = CGSize(width: body.width + NotchState.Metrics.openRadii.top * 2 + margin * 2,
                          height: body.height + margin)
        } else {
            let body = state.peeking ? state.peekSize : state.compactSize
            size = CGSize(width: body.width + NotchState.Metrics.closedRadii.top * 2, height: body.height)
        }
        return CGRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height, width: size.width, height: size.height)
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel()
        let container = NotchContainerView()
        container.controller = self
        let hosting = FirstMouseHostingView(rootView: NotchView(model: model, state: state, onTap: { [weak self] in self?.clicked() }))
        hosting.onScroll = { [weak self] event in self?.scrolled(event) }
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
        panel?.setFrame(currentFrame, display: true)
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

/// Buttons respond to the first click even though Tuno isn't active;
/// trackpad scrolls are handed to the controller as gestures.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onScroll: ((NSEvent) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
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
        let size = state.bodySize
        let radii = state.radii
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if state.expanded {
                    expanded.transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
                } else {
                    VStack(spacing: 0) {
                        compact
                        if state.peeking {
                            peekLine.transition(.opacity)
                        }
                    }
                    .transition(.opacity)
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

    /// The new track, under the closed notch.
    private var peekLine: some View {
        Text([model.reading?.title, model.reading?.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 14)
            .frame(height: NotchState.Metrics.peekLine - 4)
    }

    // MARK: Open

    private var expanded: some View {
        VStack(spacing: NotchState.Metrics.spacing) {
            Color.clear.frame(height: state.notch.height - 4)
            HStack(spacing: 12) {
                Button(action: model.onOpenApp) {
                    HStack(spacing: 12) {
                        artwork(size: NotchState.Metrics.headerHeight, radius: 10)
                            // A glow in the artwork's own colour while playing.
                            .shadow(color: Color(nsColor: tint).opacity(playing ? 0.7 : 0), radius: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            MarqueeText(text: model.reading?.title ?? "Nothing is playing",
                                        font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
                            if let subtitle {
                                MarqueeText(text: subtitle, font: .systemFont(ofSize: 12), color: Color(white: 0.63))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.appName.map { "Open \($0)" } ?? "")
                if let favorited = model.scriptState?.favorited {
                    control(favorited ? "heart.fill" : "heart", size: 14, label: favorited ? "Unfavourite" : "Favourite",
                            active: favorited, action: model.onToggleFavorite)
                }
                WaveformView(playing: playing, color: tint)
                    .frame(width: 18, height: 16)
            }
            if state.showsProgress, let reading = model.reading {
                NotchProgress(reading: reading, fill: playing ? Color(nsColor: tint) : .white,
                              onSeek: model.scriptable == nil ? nil : model.onSeek)
                    .frame(height: NotchState.Metrics.progressHeight)
            }
            controls
        }
        .padding(.horizontal, 18)
        .padding(.bottom, NotchState.Metrics.bottomPadding)
    }

    /// Previous, play/pause, next; for scriptable players also ±10 s,
    /// shuffle and repeat around them.
    @ViewBuilder
    private var controls: some View {
        let extended = model.scriptable != nil
        HStack(spacing: extended ? 14 : 28) {
            if extended {
                let shuffle = model.scriptState?.shuffle ?? false
                control("shuffle", size: 13, label: shuffle ? "Shuffle on" : "Shuffle off", active: shuffle,
                        action: model.onToggleShuffle)
                    .disabled(model.scriptState == nil)
                control("gobackward.10", size: 15, label: "Back 10 seconds") { model.onSkip(-10) }
            }
            control("backward.end.fill", size: 16, label: "Previous") { model.onCommand(.previous) }
            control(playing ? "pause.fill" : "play.fill", size: 20, label: playing ? "Pause" : "Play") {
                model.onCommand(.playPause)
            }
            control("forward.end.fill", size: 16, label: "Next") { model.onCommand(.next) }
            if extended {
                control("goforward.10", size: 15, label: "Forward 10 seconds") { model.onSkip(10) }
                let mode = model.scriptState?.repeatMode ?? .off
                control(mode == .one ? "repeat.1" : "repeat", size: 13,
                        label: mode == .off ? "Repeat off" : mode == .one ? "Repeat one" : "Repeat all",
                        active: mode != .off, action: model.onCycleRepeat)
                    .disabled(model.scriptState == nil)
            }
        }
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

    /// `active` marks a toggle that is on (shuffle, repeat, favourite): it
    /// takes the artwork's colour; when off it is dimmed.
    private func control(_ symbol: String, size: CGFloat, label: String, active: Bool? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(active.map { $0 ? Color(nsColor: model.tint ?? .white) : Color(white: 0.5) } ?? .white)
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
    var fill: Color = .white
    /// Seeks to a position in seconds; nil when the player can't seek.
    var onSeek: ((TimeInterval) -> Void)?
    /// Where the bar is being dragged to, as a fraction.
    @State private var scrub: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            let duration = reading.duration ?? 0
            let position = scrub.map { $0 * duration } ?? reading.position(at: context.date) ?? 0
            HStack(spacing: 8) {
                Text(TimeText.format(position))
                GeometryReader { geometry in
                    let fraction = CGFloat(duration > 0 ? min(position / duration, 1) : 0)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(fill)
                            .frame(width: geometry.size.width * fraction)
                    }
                    .frame(height: onSeek != nil && (hovering || scrub != nil) ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(seekGesture(width: geometry.size.width, duration: duration))
                }
                .onHover { hovering = $0 }
                Text(TimeText.format(duration))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(Color(white: 0.63))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(TimeText.format(position)) of \(TimeText.format(duration))")
        }
    }

    /// Drag or click anywhere on the bar to seek, for players that allow it.
    private func seekGesture(width: CGFloat, duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard onSeek != nil, width > 0 else { return }
                scrub = Double(min(max(value.location.x / width, 0), 1))
            }
            .onEnded { _ in
                guard let onSeek, let fraction = scrub else { return }
                onSeek(fraction * duration)
                // Hold the scrubbed position until the player reports the new one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scrub = nil }
            }
    }
}
