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
    /// - Parameter translate: if true, use green color to indicate translate mode
    func showRecording(translate: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.dismissTimer?.invalidate()
            self?.ensureWindow()
            self?.checkmark?.isHidden = true
            self?.setBarsVisible(true, translate: translate)
            self?.fadeIn()
            self?.startBarAnimation()
        }
    }
    
    /// Morph to processing state (slow pulse, keeps current bar color)
    func showProcessing() {
        DispatchQueue.main.async { [weak self] in
            self?.stopAnimation()
            self?.checkmark?.isHidden = true
            // Don't reset bar color — keep whatever was set during recording
            for bar in self?.bars ?? [] {
                bar.isHidden = false
            }
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
    
    /// Show result text with a copy button (when no text field is focused)
    func showResult(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.stopAnimation()
            self?.dismissTimer?.invalidate()
            self?.presentResultWindow(text)
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
    
    /// Update bars based on real-time audio level (called from audio thread)
    func updateAudioLevel(_ rms: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.setBarHeights(rms: rms)
        }
    }
    
    private func setBarHeights(rms: Float) {
        let centerY = pillHeight / 2
        // Map RMS (typically 0.0-0.3) to bar height with some randomness per bar
        let normalized = CGFloat(min(rms * 8.0, 1.0))  // amplify and clamp
        
        for bar in bars {
            let jitter = CGFloat.random(in: 0.6...1.0)
            let h = barMinH + (barMaxH - barMinH) * normalized * jitter
            let newFrame = NSRect(
                x: bar.frame.origin.x,
                y: centerY - h / 2,
                width: barWidth,
                height: h
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.08
                bar.animator().frame = newFrame
            }
        }
    }
    
    private func startBarAnimation() {
        // No longer using timer — bars are driven by real-time audio level
        // Just set bars to minimum height as initial state
        let centerY = pillHeight / 2
        for bar in bars {
            bar.frame = NSRect(x: bar.frame.origin.x, y: centerY - barMinH / 2, width: barWidth, height: barMinH)
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
    
    private let normalBarColor = NSColor(red: 0.45, green: 0.72, blue: 0.95, alpha: 1.0)  // soft blue
    private let translateBarColor = NSColor(white: 0.7, alpha: 1.0)  // light gray
    private var currentBarColor = NSColor(red: 0.45, green: 0.72, blue: 0.95, alpha: 1.0)
    
    private func setBarsVisible(_ visible: Bool, translate: Bool = false) {
        currentBarColor = translate ? translateBarColor : normalBarColor
        for bar in bars {
            bar.isHidden = !visible
            if visible {
                bar.layer?.backgroundColor = currentBarColor.cgColor
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
    
    // MARK: - Result Window (clipboard fallback)
    
    private var resultWindow: NSPanel?
    
    private func presentResultWindow(_ text: String) {
        // Dismiss the recording overlay first
        if let w = window {
            w.orderOut(nil)
        }
        
        // Close any existing result window
        resultWindow?.orderOut(nil)
        resultWindow = nil
        
        // Calculate size based on text
        let font = NSFont.systemFont(ofSize: 13)
        let maxWidth: CGFloat = 360
        let textSize = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth - 32, height: 200),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        )
        let panelWidth = min(max(textSize.width + 40, 160), maxWidth)
        let textHeight = min(max(textSize.height + 8, 24), 200)
        let panelHeight = textHeight + 44  // text + button + padding
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Result window IS interactive (has a button)
        panel.ignoresMouseEvents = false
        
        // Background
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.92).cgColor
        bg.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(bg)
        
        // Text label (scrollable if long)
        let textField = NSTextField(wrappingLabelWithString: text)
        textField.font = font
        textField.textColor = .white
        textField.isEditable = false
        textField.isSelectable = true
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.frame = NSRect(x: 16, y: 40, width: panelWidth - 32, height: textHeight)
        bg.addSubview(textField)
        
        // Close button (top-right)
        let closeBtn = NSButton(frame: NSRect(x: panelWidth - 28, y: panelHeight - 24, width: 20, height: 20))
        closeBtn.title = "✕"
        closeBtn.bezelStyle = .inline
        closeBtn.isBordered = false
        closeBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        closeBtn.contentTintColor = NSColor(white: 0.6, alpha: 1.0)
        closeBtn.target = self
        closeBtn.action = #selector(resultCloseClicked)
        bg.addSubview(closeBtn)
        
        // Copy button
        let copyBtn = NSButton(frame: NSRect(x: panelWidth / 2 - 40, y: 8, width: 80, height: 26))
        copyBtn.title = "📋 Copy"
        copyBtn.bezelStyle = .rounded
        copyBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        copyBtn.target = self
        copyBtn.action = #selector(resultCopyClicked(_:))
        bg.addSubview(copyBtn)
        
        // Store text for copy action
        objc_setAssociatedObject(copyBtn, "resultText", text, .OBJC_ASSOCIATION_RETAIN)
        
        // Position: bottom center of active screen
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.visibleFrame
        let x = sf.midX - panelWidth / 2
        let y = sf.origin.y + 80
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        
        // Fade in
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1.0
        }
        
        self.resultWindow = panel
        
        // Auto-dismiss after 8 seconds if not clicked
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            self?.dismissResultWindow()
        }
    }
    
    @objc private func resultCloseClicked() {
        dismissResultWindow()
    }
    
    @objc private func resultCopyClicked(_ sender: NSButton) {
        if let text = objc_getAssociatedObject(sender, "resultText") as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Log.info("📋 Result copied to clipboard")
        }
        dismissResultWindow()
    }
    
    private func dismissResultWindow() {
        guard let w = resultWindow else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            w.orderOut(nil)
            self?.resultWindow = nil
        })
    }
}
