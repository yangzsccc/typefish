import AppKit

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    
    var state: AppState!
    var menuBar: MenuBarController!
    var hotkeyManager: HotkeyManager!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.clear()
        Log.info("🐟 TypeFish starting...")
        
        // Menu bar only app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
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
        
        // Set up global hotkey
        hotkeyManager = HotkeyManager()
        hotkeyManager.onToggle = { [weak self] in
            self?.state.toggleRecording()
        }
        hotkeyManager.onTranslateToggle = { [weak self] in
            self?.state.toggleTranslateRecording()
        }
        hotkeyManager.onCancel = { [weak self] in
            self?.state.cancelRecording()
        }
        hotkeyManager.start()
        
        // Listen for audio device changes (headphone connect/disconnect)
        state.recorder.onDeviceChange = { [weak self] in
            guard let self = self else { return }
            if self.state.isRecording {
                self.state.cancelRecording()
                Log.info("⚠️ Recording cancelled due to device change")
            }
        }
        state.recorder.startDeviceChangeListener()
        
        Log.info("🐟 TypeFish ready! Press Option+Space to start dictating.")
        
        // Clean up old transcription logs (keep 7 days)
        DispatchQueue.global().async {
            TranscriptionLogger.cleanOldFiles()
        }
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
