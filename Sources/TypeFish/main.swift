import AppKit

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    static let defaultActivationPolicy: NSApplication.ActivationPolicy = .accessory
    
    var state: AppState!
    var menuBar: MenuBarController!
    var hotkeyManager: HotkeyManager!
    var mainWindow: MainWindow!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.rotate()
        Log.info("🐟 TypeFish starting...")
        
        // Keep TypeFish as a menu bar app so it does not compete with the target app for focus.
        NSApp.setActivationPolicy(Self.defaultActivationPolicy)
        NSApp.mainMenu = ApplicationMenuFactory.makeMainMenu()
        
        // Initialize state
        state = AppState()
        
        // Request microphone permission
        AudioRecorder.requestPermission { granted in
            if !granted {
                Log.info("⚠️ Microphone permission denied — recording won't work")
            }
        }
        
        // Set up menu bar
        menuBar = MenuBarController(state: state)
        
        // Set up main window (shown when clicking Dock icon)
        mainWindow = MainWindow(state: state)
        menuBar.onOpenMainWindow = { [weak self] in
            self?.mainWindow.showWindow()
        }
        
        // Set up global hotkey
        hotkeyManager = HotkeyManager()
        hotkeyManager.onToggle = { [weak self] in
            self?.state.toggleRecording()
        }
        hotkeyManager.onTranslateToggle = { [weak self] in
            self?.state.toggleTranslateRecording()
        }
        hotkeyManager.onCommandToggle = { [weak self] in
            self?.state.toggleCommandRecording()
        }
        hotkeyManager.onCancel = { [weak self] in
            self?.state.cancelRecording()
        }
        EditTracker.shared.configure(hotkeyManager: hotkeyManager)
        hotkeyManager.start()
        
        // Chain main window updates to state changes (MenuBarController already set onStateChange)
        let menuBarCallback = state.onStateChange
        state.onStateChange = { [weak self] in
            menuBarCallback?()
            self?.mainWindow.updateStatus()
        }
        
        // Listen for audio device changes (headphone connect/disconnect)
        // AudioRecorder handles engine restart internally.
        // This callback just syncs AppState UI when recording is interrupted.
        state.recorder.onDeviceChange = { [weak self] in
            guard let self = self else { return }
            Log.info("⚠️ Device change callback: AppState.isRecording=\(self.state.isRecording) recorder.isRecording=\(self.state.recorder.isRecording)")
            if self.state.isRecording && !self.state.recorder.isRecording {
                // Recorder already stopped itself — just sync UI state
                self.state.isRecording = false
                self.state.isProcessing = false
                self.state.statusText = "🔄 Mic switched"
                self.state.onStateChange?()
                self.state.overlay.dismiss()
                self.state.cancelSound?.play()
                Log.info("⚠️ Recording interrupted by device change — UI reset")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if !self.state.isRecording && !self.state.isProcessing {
                        self.state.statusText = "Ready"
                        self.state.onStateChange?()
                    }
                }
            }
        }
        state.recorder.startDeviceChangeListener()
        
        Log.info("🐟 TypeFish ready! Press Option+Space to start dictating.")
        
        // Clean up old transcription logs (keep 7 days)
        DispatchQueue.global().async {
            TranscriptionLogger.cleanOldFiles()
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show main window when Dock icon is clicked
        mainWindow.showWindow()
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
