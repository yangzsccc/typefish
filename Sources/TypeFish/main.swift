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
        hotkeyManager.start()
        
        Log.info("🐟 TypeFish ready! Press Option+Space to start dictating.")
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
