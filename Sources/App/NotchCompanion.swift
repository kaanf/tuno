//
//  NotchCompanion.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import SwiftUI

/// Where a screen's camera notch is, if it has one.
struct NotchGeometry: Equatable {
    /// The notch, in global screen coordinates (origin bottom left).
    let rect: CGRect

    init?(screen: NSScreen) {
        let height = screen.safeAreaInsets.top
        guard height > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        rect = CGRect(x: left.maxX, y: screen.frame.maxY - height, width: right.minX - left.maxX, height: height)
    }

    /// The first screen with a notch: the built-in display, when it is on.
    static var current: NotchGeometry? {
        NSScreen.screens.lazy.compactMap(NotchGeometry.init(screen:)).first
    }
}

/// Size and state shared between the controller and the SwiftUI view.
final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var notch = CGSize(width: 180, height: 32)
    /// Whether the expanded player has a progress row (not for live streams).
    @Published var showsProgress = true

    enum Metrics {
        /// Black added beside the notch on each side in the compact state.
        static let wing: CGFloat = 50
        static let compactRadius: CGFloat = 12
        static let expandedWidth: CGFloat = 360
        static let expandedRadius: CGFloat = 26
        static let spacing: CGFloat = 12
        static let bottomPadding: CGFloat = 12
        static let headerHeight: CGFloat = 52
        static let progressHeight: CGFloat = 12
        static let controlsHeight: CGFloat = 28
        /// Room around the expanded panel for its shadow.
        static let shadowMargin: CGFloat = 24
    }

    var compactSize: CGSize { CGSize(width: notch.width + Metrics.wing * 2, height: notch.height) }
    /// Sized to its content, so there's no slack under the controls.
    var expandedSize: CGSize {
        var body = Metrics.spacing + Metrics.headerHeight + Metrics.spacing + Metrics.controlsHeight + Metrics.bottomPadding
        if showsProgress { body += Metrics.progressHeight + Metrics.spacing }
        // The content starts a little above the notch's bottom edge (see `expanded`).
        return CGSize(width: max(Metrics.expandedWidth, notch.width + 120), height: notch.height - 4 + body)
    }
}

/// The notch companion: a black extension of the notch showing the artwork
/// and waveform, which opens into a small player on hover or click.
final class NotchController {
    let model = PlayerModel()
    private let state = NotchState()
    private var panel: NotchPanel?
    private var geometry: NotchGeometry?
    private var hoverTimer: Timer?
    private var pendingExpand: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    private var screenObserver: Any?
    /// Opened from the keyboard: stays open until the pointer has been in
    /// and out, or the shortcut is pressed again.
    private var heldOpen = false {
        didSet { watchOutsideClicks(heldOpen) }
    }
    private var outsideClickMonitor: Any?

    var isShown: Bool { panel?.isVisible == true }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Shows the companion with the model's current contents, if this Mac
    /// has a notch screen attached.
    func show() {
        let hasProgress = (model.reading?.duration ?? 0) > 0
        if state.showsProgress != hasProgress {
            state.showsProgress = hasProgress
            if state.expanded { panel?.setFrame(frame(expanded: true), display: true) }
        }
        guard let geometry = NotchGeometry.current else { return hide() }
        let panel = self.panel ?? makePanel()
        if geometry != self.geometry {
            self.geometry = geometry
            state.notch = geometry.rect.size
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

    // MARK: - Expanding

    /// The global shortcut: open the player, or close it if it's open.
    func toggleFromKeyboard() {
        cancelPending()
        if state.expanded {
            heldOpen = false
            setExpanded(false)
        } else {
            heldOpen = true
            setExpanded(true)
        }
    }

    fileprivate func pointerEntered() {
        heldOpen = false
        cancelCollapse()
        guard !state.expanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pointerInside else { return }
            self.setExpanded(true)
        }
        pendingExpand = work
        // A short delay, so sweeping the pointer across the top of the screen
        // doesn't pop the player open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func setExpanded(_ expanded: Bool) {
        guard let panel, state.expanded != expanded else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)
        if expanded {
            // Grow the window first and settle the layout at that size without
            // animation; otherwise SwiftUI animates the re-centring too and the
            // shape flies in from the old window's corner. Then expand inside it.
            panel.setFrame(frame(expanded: true), display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in
                withAnimation(reduceMotion ? nil : spring) { self?.state.expanded = true }
            }
            watchHover(true)
        } else {
            watchHover(false)
            withAnimation(reduceMotion ? nil : spring) { state.expanded = false }
            // Shrink the window once the shape has, so the transparent area
            // around it never blocks clicks on the menu bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.4)) { [weak self] in
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

    /// Top-centred on the notch. Expanded, it includes room for the shadow.
    private func frame(expanded: Bool) -> CGRect {
        guard let notch = geometry?.rect else { return .zero }
        let margin = NotchState.Metrics.shadowMargin
        let size = expanded
            ? CGSize(width: state.expandedSize.width + margin * 2, height: state.expandedSize.height + margin)
            : state.compactSize
        return CGRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height, width: size.width, height: size.height)
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel()
        let container = NotchContainerView()
        container.controller = self
        let hosting = FirstMouseHostingView(rootView: NotchView(model: model, state: state, onTap: { [weak self] in self?.clicked() }))
        hosting.translatesAutoresizingMaskIntoConstraints = true
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

/// A rectangle with only its bottom corners rounded, hanging from the top
/// edge of the screen like the notch itself.
private struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct NotchView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var state: NotchState
    let onTap: () -> Void

    var body: some View {
        let size = state.expanded ? state.expandedSize : state.compactSize
        let radius = state.expanded ? NotchState.Metrics.expandedRadius : NotchState.Metrics.compactRadius
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if state.expanded {
                    expanded.transition(.opacity)
                } else {
                    compact.transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(NotchShape(radius: radius).fill(Color.black))
            .clipShape(NotchShape(radius: radius))
            .shadow(color: .black.opacity(state.expanded ? 0.35 : 0), radius: 15, y: 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        // With the menu bar item gone, this is the way to Settings and Quit.
        .contextMenu {
            Button("Settings…", action: model.onSettings)
            Button("Quit Tuno", action: model.onQuit)
        }
    }

    private var playing: Bool { model.reading?.isPlaying ?? false }
    private var tint: NSColor { playing ? (model.tint ?? .white) : .secondaryLabelColor }

    // MARK: Compact

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

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: NotchState.Metrics.spacing) {
            Color.clear.frame(height: state.notch.height - 4)
            HStack(spacing: 12) {
                artwork(size: 52, radius: 10)
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

    @ViewBuilder
    private func artwork(size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let image = model.reading?.artwork ?? model.fallbackArtwork {
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
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Elapsed time, bar and duration on one line, as in the design.
private struct NotchProgress: View {
    let reading: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            let position = reading.position(at: context.date) ?? 0
            let duration = reading.duration ?? 0
            HStack(spacing: 8) {
                Text(PlaybackProgress.format(position))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white)
                            .frame(width: geometry.size.width * CGFloat(duration > 0 ? position / duration : 0))
                    }
                }
                .frame(height: 4)
                Text(PlaybackProgress.format(duration))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(Color(white: 0.63))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(PlaybackProgress.format(position)) of \(PlaybackProgress.format(duration))")
        }
    }
}
