import Foundation
import AppKit

/// Checks GitHub Releases for new versions and offers to update.
struct Updater {
    
    static let currentVersion = "1.3.0"
    static let repo = "yangzsccc/typefish"
    static let releasesAPI = "https://api.github.com/repos/yangzsccc/typefish/releases/latest"
    
    /// Check for updates in background. Shows alert only if new version found.
    static func checkInBackground() {
        DispatchQueue.global(qos: .utility).async {
            guard let (tag, downloadURL) = fetchLatestRelease() else { return }
            
            let remote = tag.replacingOccurrences(of: "v", with: "")
            guard remote.compare(currentVersion, options: .numeric) == .orderedDescending else {
                Log.info("📦 Up to date (v\(currentVersion))")
                return
            }
            
            Log.info("📦 Update available: v\(currentVersion) → v\(remote)")
            
            DispatchQueue.main.async {
                promptUpdate(newVersion: remote, downloadURL: downloadURL)
            }
        }
    }
    
    /// Manual check (shows "up to date" if no update)
    static func checkManually() {
        DispatchQueue.global(qos: .utility).async {
            guard let (tag, downloadURL) = fetchLatestRelease() else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Update Check Failed"
                    alert.informativeText = "Could not reach GitHub. Check your internet connection."
                    alert.runModal()
                }
                return
            }
            
            let remote = tag.replacingOccurrences(of: "v", with: "")
            
            DispatchQueue.main.async {
                if remote.compare(currentVersion, options: .numeric) == .orderedDescending {
                    promptUpdate(newVersion: remote, downloadURL: downloadURL)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "You're Up to Date"
                    alert.informativeText = "TypeFish v\(currentVersion) is the latest version."
                    alert.runModal()
                }
            }
        }
    }
    
    // MARK: - Private
    
    private static func fetchLatestRelease() -> (tag: String, downloadURL: String)? {
        guard let url = URL(string: releasesAPI) else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        
        let sem = DispatchSemaphore(value: 0)
        var result: (String, String)?
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else { return }
            
            // Find the .zip asset
            let zipAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            guard let downloadURL = zipAsset?["browser_download_url"] as? String else { return }
            
            result = (tag, downloadURL)
        }.resume()
        
        sem.wait()
        return result
    }
    
    private static func promptUpdate(newVersion: String, downloadURL: String) {
        let alert = NSAlert()
        alert.messageText = "TypeFish Update Available"
        alert.informativeText = "v\(currentVersion) → v\(newVersion)\n\nDownload and install the update?"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        
        downloadAndInstall(from: downloadURL)
    }
    
    private static func downloadAndInstall(from urlString: String) {
        guard let url = URL(string: urlString) else { return }
        
        Log.info("📦 Downloading update from \(urlString)")
        
        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            guard let tempURL = tempURL, error == nil else {
                Log.info("❌ Download failed: \(error?.localizedDescription ?? "unknown")")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Download Failed"
                    alert.informativeText = error?.localizedDescription ?? "Unknown error"
                    alert.runModal()
                }
                return
            }
            
            // Unzip and replace
            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory.appendingPathComponent("typefish-update-\(UUID().uuidString)")
            
            do {
                try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                
                // Unzip
                let unzipProcess = Process()
                unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzipProcess.arguments = ["-o", tempURL.path, "-d", tmpDir.path]
                try unzipProcess.run()
                unzipProcess.waitUntilExit()
                
                // Find TypeFish.app in extracted files
                let extracted = try fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
                guard let newApp = extracted.first(where: { $0.lastPathComponent == "TypeFish.app" }) else {
                    Log.info("❌ TypeFish.app not found in downloaded zip")
                    return
                }
                
                // Get current app location
                let currentApp = Bundle.main.bundleURL
                let backupURL = currentApp.deletingLastPathComponent()
                    .appendingPathComponent("TypeFish-old.app")
                
                // Replace: backup current → move new → restart
                try? fm.removeItem(at: backupURL)
                try fm.moveItem(at: currentApp, to: backupURL)
                try fm.moveItem(at: newApp, to: currentApp)
                try? fm.removeItem(at: backupURL)
                try? fm.removeItem(at: tmpDir)
                
                Log.info("📦 Update installed! Restarting...")
                
                // Restart: launch a background script that waits for us to quit, then reopens
                DispatchQueue.main.async {
                    let appPath = currentApp.path
                    let pid = ProcessInfo.processInfo.processIdentifier
                    
                    // Shell script: wait for current process to die, then open the new app
                    let script = """
                    while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
                    sleep 0.5
                    open "\(appPath)"
                    """
                    
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/bin/bash")
                    task.arguments = ["-c", script]
                    try? task.run()
                    
                    // Quit current app
                    NSApp.terminate(nil)
                }
                
            } catch {
                Log.info("❌ Update install failed: \(error)")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Update Failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
        task.resume()
    }
}
