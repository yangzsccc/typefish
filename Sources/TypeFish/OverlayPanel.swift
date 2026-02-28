import AppKit
import QuartzCore

/// A minimal floating indicator at the bottom center of the screen.
/// Shows animated bars during recording, morphs for processing, then dismisses.
class OverlayPanel {
    
    private var window: NSPanel?
    private var bars: [NSView] = []
    private var checkmark: NSTextField?
    private var animTimer: Timer?
    private var dismissTimer: Timer?
    
    private let pillWidth: CGFloat = 48
    private let pillHeight: CGFloat = 28
    private let barCount = 4
    private let barWidth: CGFloat = 3.0
    private let barGap: CGFloat = 3.0
    private let barMinH: CGFloat = 4.0
    private let barMaxH: CGFloat = 16.0
    
    // MARK: - Public API
    
    /// Show animated equalizer bars (recording state)
    func showRecording() {
        DispatchQueue.main.async { [weak self] in
            self?.dismissTimer?.invalidate()
            self?.ensureWindow()
            self?.checkmark?.isHidden = true
            self?.setBarsVisible(true)
            self?.fadeIn()
            self?.startBarAnimation()
        }
    }
    
    /// Morph to processing state (slow pulse)
    func showProcessing() {
        DispatchQueue.main.async { [weak self] in
            self?.stopAnimation()
            self?.checkmark?.isHidden = true
            self?.setBarsVisible(true)
            self?.startProcessingAnimation()
        }
    }
    
    /// Flash checkmark then dismiss
    func showDone() {
        DispatchQueue.main.async { [weak self] in
            self?.stopAnimation()
            self?.setBarsVisible(false)
            self?.checkmark?.isHidden = false
            self?.dismissAfter(0.6)
        }
    }
    
    /// Dismiss immediately
    func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.stopAnimation()
            self?.dismissTimer?.invalidate()
            self?.fadeOut()
        }
    }
    
    // MARK: - Window
    
    private func ensureWindow() {
        if window != nil { return }
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Pill background
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight))
        bg.wantsLayer = true
        bg.layer?.cornerRadius = pillHeight / 2
        bg.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.88).cgColor
        bg.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(bg)
        
        // Equalizer bars
        let totalBarsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = (pillWidth - totalBarsWidth) / 2
        let centerY = pillHeight / 2
        
        bars = []
        for i in 0..<barCount {
            let x = startX + CGFloat(i) * (barWidth + barGap)
            let bar = NSView(frame: NSRect(x: x, y: centerY - barMinH / 2, width: barWidth, height: barMinH))
            bar.wantsLayer = true
            bar.layer?.cornerRadius = barWidth / 2
            bar.layer?.backgroundColor = NSColor(red: 0.45, green: 0.72, blue: 0.95, alpha: 1.0).cgColor
            bg.addSubview(bar)
            bars.append(bar)
        }
        
        // Checkmark (hidden initially)
        let check = NSTextField(labelWithString: "✓")
        check.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        check.textColor = NSColor(red: 0.3, green: 0.85, blue: 0.45, alpha: 1.0)
        check.alignment = .center
        check.frame = NSRect(x: 0, y: 3, width: pillWidth, height: 22)
        check.isHidden = true
        bg.addSubview(check)
        self.checkmark = check
        
        // Position will be set on show
        panel.setFrame(NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight), display: false)
        
        self.window = panel
    }
    
    // MARK: - Bar Animations
    
    private func startBarAnimation() {
        stopAnimation()
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.randomizeBars()
        }
    }
    
    private func randomizeBars() {
        let centerY = pillHeight / 2
        for bar in bars {
            let h = CGFloat.random(in: barMinH...barMaxH)
            let newFrame = NSRect(
                x: bar.frame.origin.x,
                y: centerY - h / 2,
                width: barWidth,
                height: h
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                bar.animator().frame = newFrame
            }
        }
    }
    
    private func startProcessingAnimation() {
        stopAnimation()
        // Gentle synchronized pulse — all bars same height, slow breathe
        let centerY = pillHeight / 2
        var phase = false
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase.toggle()
            let h: CGFloat = phase ? 10 : 5
            for bar in self.bars {
                // Change color to orange for processing
                bar.layer?.backgroundColor = NSColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0).cgColor
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.4
                    bar.animator().frame = NSRect(x: bar.frame.origin.x, y: centerY - h / 2, width: self.barWidth, height: h)
                }
            }
        }
    }
    
    private func stopAnimation() {
        animTimer?.invalidate()
        animTimer = nil
    }
    
    private func setBarsVisible(_ visible: Bool) {
        // Reset bar color to red
        for bar in bars {
            bar.isHidden = !visible
            if visible {
                bar.layer?.backgroundColor = NSColor(red: 0.45, green: 0.72, blue: 0.95, alpha: 1.0).cgColor
            }
        }
    }
    
    // MARK: - Fade
    
    /// Position the pill on the screen where the mouse cursor is
    private func positionOnActiveScreen() {
        guard let w = window else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.visibleFrame
        let x = sf.midX - pillWidth / 2
        let y = sf.origin.y + 80
        w.setFrame(NSRect(x: x, y: y, width: pillWidth, height: pillHeight), display: true)
    }
    
    private func fadeIn() {
        guard let w = window else { return }
        positionOnActiveScreen()
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            w.animator().alphaValue = 1.0
        }
    }
    
    private func fadeOut() {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil)
        })
    }
    
    private func dismissAfter(_ seconds: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }
}
