import AppKit

/// Draws squiggly underlines under every issue of the current proofread session, inside one
/// click-through panel sized to the field's frame.
///
/// Lifetime: shown when a check lands (`applyResults`) and hidden by `end()`. While visible the
/// overlay owns three passive hide triggers of its own -- scrolling, typing and app switches all
/// invalidate the geometry, and drifting squiggles over moved text are actively misleading, so the
/// underlines simply go away until the next check. Issues whose bounds the app will not report
/// (Electron/web fields) are skipped silently -- the feature degrades to the popup-only behavior.
@MainActor
final class UnderlineOverlay {
    private var panel: NSPanel?
    private var scrollMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var refreshWork: DispatchWorkItem?
    /// What is currently drawn, so scroll and window moves can be followed by re-measuring.
    private var shownIssues: [TextIssue] = []
    private var shownElement: AXUIElement?
    private var shownFieldFrame: CGRect = .zero

    func show(issues: [TextIssue], element: AXUIElement) {
        shownIssues = issues
        shownElement = element
        guard let fieldQuartz = ProofreadAX.frame(of: element) else { hide(); return }
        let primaryHeight = Self.primaryScreenHeight()
        let field = UnderlineGeometry.appKitRect(fromQuartz: fieldQuartz, primaryScreenHeight: primaryHeight)

        var segments: [(rect: CGRect, color: NSColor)] = []
        for issue in issues {
            guard let quartz = ProofreadAX.boundsForRange(issue.range, in: element),
                  let probe = ProofreadAX.boundsForRange(
                      NSRange(location: issue.range.location, length: 1), in: element),
                  UnderlineGeometry.isSingleLine(rangeRect: quartz, probeRect: probe) else { continue }
            let screen = UnderlineGeometry.appKitRect(fromQuartz: quartz, primaryScreenHeight: primaryHeight)
            // Panel-local coordinates.
            let local = CGRect(x: screen.minX - field.minX, y: screen.minY - field.minY,
                               width: screen.width, height: screen.height)
            segments.append((rect: local, color: Self.color(for: issue.kind)))
        }
        guard !segments.isEmpty else { hide(); return }
        shownFieldFrame = fieldQuartz

        let panel = self.panel ?? makePanel()
        let view = (panel.contentView as? UnderlineView) ?? UnderlineView()
        view.segments = segments
        panel.contentView = view
        panel.setFrame(field, display: true)
        panel.orderFront(nil) // NOT makeKey: the text field must keep focus.
        installHideTriggers()
    }

    func hide() {
        panel?.orderOut(nil)
        shownIssues = []
        shownElement = nil
        shownFieldFrame = .zero
        removeHideTriggers()
    }

    /// Re-measures and redraws what is already shown. Cheap enough for scrolling: a couple of AX
    /// calls per issue, and only while the overlay is visible.
    private func refresh() {
        guard let element = shownElement, !shownIssues.isEmpty else { return }
        show(issues: shownIssues, element: element)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true // click-through: clicks belong to the app underneath
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    /// Colors mirror ProofreadPopover.color (SwiftUI Color there, NSColor here); keep them in sync.
    /// Spelling is purple, not red: macOS draws its own red squiggles in many apps and the two
    /// must not be mistaken for each other.
    private static func color(for kind: IssueKind) -> NSColor {
        switch kind {
        case .spelling: return .systemPurple
        case .grammar: return .systemOrange
        case .punctuation: return .systemBlue
        case .style: return .systemGray
        }
    }

    private static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
    }

    // MARK: - Hide triggers

    /// Scrolling and window moves shift the text under the squiggles, so re-measure and follow it.
    /// (Typing is handled by the controller: it hides the underlines and re-checks after the pause.)
    /// An app switch means this field is no longer on screen: hide.
    private func installHideTriggers() {
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
        if refreshTimer == nil {
            // No AX notifications for window moves/resizes: poll the field frame instead. Only runs
            // while the overlay is visible.
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let element = self.shownElement else { return }
                    guard let frame = ProofreadAX.frame(of: element) else { self.hide(); return }
                    if frame != self.shownFieldFrame { self.refresh() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
        if appSwitchObserver == nil {
            appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    private func removeHideTriggers() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = nil
        refreshWork?.cancel()
        refreshWork = nil
    }

    /// Coalesces the burst of scroll events into one re-measure.
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}

// MARK: - Drawing

/// Strokes a squiggle along the bottom edge of each segment rect.
private final class UnderlineView: NSView {
    var segments: [(rect: CGRect, color: NSColor)] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        for segment in segments {
            let points = UnderlineGeometry.squigglePoints(width: segment.rect.width,
                                                          amplitude: 2.5, wavelength: 5)
            guard points.count > 1 else { continue }
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: segment.rect.minX + points[0].x,
                                  y: segment.rect.minY + points[0].y))
            for p in points.dropFirst() {
                path.line(to: NSPoint(x: segment.rect.minX + p.x, y: segment.rect.minY + p.y))
            }
            segment.color.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }
    }
}
