import AVFoundation
import ObjCExceptionCatcher

/// Records microphone audio to a file using AVAudioEngine.
/// Outputs 16kHz mono WAV (optimal for Whisper).
/// Tracks peak audio level to detect silence.
///
/// Architecture: Engine + tap run continuously after startEngine().
/// startRecording() just creates a file (instant). stopRecording() nils it.
/// The tap callback writes only when audioFile != nil.
class AudioRecorder {
    
    private var audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private(set) var isRecording = false
    
    /// Whether the engine is running with tap installed
    private(set) var isEngineRunning = false
    
    /// Preferred microphone identifier (partial match on ID or name)
    var preferredMicrophone: String? = nil
    
    /// Listener ID for audio device changes
    private var deviceChangeListenerID: AudioObjectPropertyListenerBlock?
    
    /// Called when audio device changes (for UI recovery)
    var onDeviceChange: (() -> Void)?
    
    /// Peak RMS level during recording (0.0 = silence, 1.0 = max)
    private(set) var peakRMSLevel: Float = 0.0
    
    /// Real-time audio level callback (called on audio thread)
    var onAudioLevel: ((Float) -> Void)?
    
    /// Flag to suppress device change listener when WE cause the change
    private var suppressDeviceChange = false
    
    /// Cached device ID for preferred microphone (avoids re-enumeration)
    private var preferredDeviceID: AudioDeviceID = 0
    
    /// Start the audio engine with tap installed. Engine stays running
    /// so that startRecording() is instant (just creates a file).
    /// Call once at app launch (background thread OK).
    func startEngine() {
        guard !isEngineRunning else { return }
        
        let start = CFAbsoluteTimeGetCurrent()
        
        audioEngine.reset()
        
        // Select preferred microphone if configured
        if let pref = preferredMicrophone, !pref.isEmpty {
            selectMicrophone(matching: pref)
        }
        
        let inputNode = audioEngine.inputNode
        
        // Bind AudioUnit directly to preferred device
        if preferredDeviceID != 0, let audioUnit = inputNode.audioUnit {
            var devID = preferredDeviceID
            let auStatus = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if auStatus == noErr {
                Log.info("🎤 AudioUnit input locked to preferred mic (id: \(preferredDeviceID))")
            } else {
                Log.info("⚠️ AudioUnit device set returned \(auStatus) — relying on system default")
            }
        }
        
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard inputFormat.sampleRate > 0 else {
            Log.info("❌ No microphone input available")
            return
        }
        
        // Target format: 16kHz mono (Whisper's native rate)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            Log.info("❌ Failed to create target audio format")
            return
        }
        
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Log.info("❌ Failed to create audio converter")
            return
        }
        
        // Install tap — writes to audioFile when non-nil, discards otherwise
        if !installTapSafely(on: inputNode, format: inputFormat, targetFormat: targetFormat, converter: converter) {
            Log.info("⚠️ Tap install failed, retrying with engine reset...")
            audioEngine.reset()
            
            if let pref = preferredMicrophone, !pref.isEmpty {
                selectMicrophone(matching: pref)
            }
            
            let retryNode = audioEngine.inputNode
            let retryFormat = retryNode.outputFormat(forBus: 0)
            guard retryFormat.sampleRate > 0 else {
                Log.info("❌ No microphone available after reset")
                return
            }
            guard let retryConverter = AVAudioConverter(from: retryFormat, to: targetFormat) else {
                Log.info("❌ Failed to create converter on retry")
                return
            }
            
            if !installTapSafely(on: retryNode, format: retryFormat, targetFormat: targetFormat, converter: retryConverter) {
                Log.info("❌ Tap install failed on retry too")
                return
            }
        }
        
        do {
            try audioEngine.start()
            isEngineRunning = true
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            Log.info("🔥 Audio engine started in \(String(format: "%.1f", elapsed))s (rate: \(Int(inputFormat.sampleRate))Hz) — always-on mode")
        } catch {
            Log.info("❌ Audio engine failed to start: \(error.localizedDescription)")
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }
    
    /// Restart the engine (e.g. after device change)
    func restartEngine() {
        Log.info("🔄 Restarting audio engine...")
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isEngineRunning = false
        audioEngine.reset()
        startEngine()
    }
    
    /// Lock system default input to preferred microphone at app startup.
    func lockPreferredMicrophone() {
        guard let pref = preferredMicrophone, !pref.isEmpty else { return }
        
        let deviceID = findInputDevice(matching: pref)
        guard deviceID != 0 else {
            Log.info("⚠️ Preferred mic '\(pref)' not found — cannot lock input device")
            return
        }
        
        preferredDeviceID = deviceID
        setSystemDefaultInput(deviceID: deviceID)
        Log.info("🔒 Locked system input to preferred mic (prevents BT switching)")
    }
    
    deinit {
    }
    
    /// Start recording microphone to a temporary file.
    /// Engine must already be running (call startEngine first).
    /// This is instant — just creates a file for the tap to write to.
    func startRecording() -> Bool {
        guard !isRecording else { return false }
        
        // Start engine if not running (fallback)
        if !isEngineRunning {
            Log.info("⚠️ Engine not running, starting now...")
            startEngine()
            guard isEngineRunning else {
                Log.info("❌ Failed to start engine")
                return false
            }
        }
        
        peakRMSLevel = 0.0
        
        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "typefish_\(Int(Date().timeIntervalSince1970)).wav"
        let url = tempDir.appendingPathComponent(filename)
        self.outputURL = url
        
        // Target format: 16kHz mono
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            Log.info("❌ Failed to create target audio format")
            return false
        }
        
        // Create audio file — tap will start writing immediately
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: targetFormat.settings)
        } catch {
            Log.info("❌ Failed to create audio file: \(error.localizedDescription)")
            return false
        }
        
        isRecording = true
        Log.info("🎙️ Recording started → \(url.lastPathComponent)")
        return true
    }
    
    /// Stop recording and return the file URL
    func stopRecording() -> URL? {
        guard isRecording else {
            forceCleanup()
            return nil
        }
        
        // Stop writing — tap keeps running but discards buffers
        audioFile = nil
        isRecording = false
        
        // Engine keeps running for next recording
        
        guard let url = outputURL else { return nil }
        
        // Check file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            Log.info("🎙️ Recording stopped: \(size / 1024)KB")
        }
        
        return url
    }
    
    /// Force cleanup recording state (not engine).
    func forceCleanup() {
        audioFile = nil
        isRecording = false
        Log.info("🧹 AudioRecorder force cleanup")
    }
    
    /// Check if audio was basically silence (Whisper hallucination prevention)
    func wasSilent(threshold: Float = 0.01) -> Bool {
        let silent = peakRMSLevel < threshold
        if silent {
            Log.info("🔇 Audio was silence (peak RMS: \(String(format: "%.4f", peakRMSLevel)))")
        } else {
            Log.info("🔊 Audio peak RMS: \(String(format: "%.4f", peakRMSLevel))")
        }
        return silent
    }
    
    /// Safely install a tap, catching ObjC exceptions from AVAudioEngine format mismatches
    private func installTapSafely(
        on node: AVAudioInputNode,
        format inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> Bool {
        var objcError: NSError?
        let success = ObjCTry({
            let needsConversion = inputFormat.sampleRate != 16000 || inputFormat.channelCount != 1
            
            if needsConversion {
                node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                    guard let self = self else { return }
                    
                    // Only write + track levels when recording
                    guard let file = self.audioFile else { return }
                    self.updatePeakLevel(buffer: buffer)
                    
                    let ratio = inputFormat.sampleRate / 16000.0
                    let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) / ratio)
                    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }
                    
                    var error: NSError?
                    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if error == nil && convertedBuffer.frameLength > 0 {
                        try? file.write(from: convertedBuffer)
                    }
                }
            } else {
                node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                    guard let self = self else { return }
                    guard let file = self.audioFile else { return }
                    self.updatePeakLevel(buffer: buffer)
                    try? file.write(from: buffer)
                }
            }
        }, &objcError)
        
        if !success {
            Log.info("❌ installTap threw exception: \(objcError?.localizedDescription ?? "unknown")")
            node.removeTap(onBus: 0)
        }
        return success
    }
    
    /// Calculate RMS of a buffer and update peak
    private func updatePeakLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        
        var sum: Float = 0
        let data = channelData[0]
        for i in 0..<frames {
            let sample = data[i]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(frames))
        if rms > peakRMSLevel {
            peakRMSLevel = rms
        }
        onAudioLevel?(rms)
    }
    
    /// Trim trailing silence from a WAV file to prevent Whisper hallucination.
    static func trimTrailingSilence(fileURL: URL, threshold: Float = 0.008) -> URL? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return nil }
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        
        guard let channelData = buffer.floatChannelData else { return nil }
        let data = channelData[0]
        let sampleRate = Int(format.sampleRate)
        
        let chunkSize = sampleRate / 20  // 50ms chunks
        var lastSpeechFrame = Int(totalFrames)
        
        var i = Int(totalFrames) - chunkSize
        while i >= 0 {
            var sum: Float = 0
            let end = min(i + chunkSize, Int(totalFrames))
            for j in i..<end {
                let s = data[j]
                sum += s * s
            }
            let rms = sqrtf(sum / Float(end - i))
            if rms > threshold {
                lastSpeechFrame = end
                break
            }
            i -= chunkSize
        }
        
        let bufferFrames = sampleRate / 2
        let trimFrame = min(lastSpeechFrame + bufferFrames, Int(totalFrames))
        
        let removedFrames = Int(totalFrames) - trimFrame
        guard removedFrames > sampleRate else { return nil }
        
        let removedMs = removedFrames * 1000 / sampleRate
        Log.info("✂️ Trimmed \(removedMs)ms trailing silence")
        
        let trimmedURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("trimmed_\(fileURL.lastPathComponent)")
        
        guard let trimmedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(trimFrame)) else { return nil }
        memcpy(trimmedBuffer.floatChannelData![0], data, trimFrame * MemoryLayout<Float>.size)
        trimmedBuffer.frameLength = AVAudioFrameCount(trimFrame)
        
        do {
            let outFile = try AVAudioFile(forWriting: trimmedURL, settings: format.settings)
            try outFile.write(from: trimmedBuffer)
            return trimmedURL
        } catch {
            Log.info("⚠️ Failed to write trimmed audio: \(error)")
            return nil
        }
    }
    
    // MARK: - Device Management
    
    private func findInputDevice(matching query: String) -> AudioDeviceID {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize)
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &deviceIDs)
        
        for did in deviceIDs {
            var inputScope = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufferSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(did, &inputScope, 0, nil, &bufferSize)
            if bufferSize == 0 { continue }
            
            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            AudioObjectGetPropertyData(did, &inputScope, 0, nil, &bufferSize, bufferList)
            let inputChannels = bufferList.pointee.mBuffers.mNumberChannels
            bufferList.deallocate()
            if inputChannels == 0 { continue }
            
            var nameProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(did, &nameProperty, 0, nil, &nameSize, &name)
            let deviceName = name as String
            
            var uidProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(did, &uidProperty, 0, nil, &uidSize, &uid)
            let deviceUID = uid as String
            
            let queryLower = query.lowercased()
            if deviceName.lowercased().contains(queryLower) || deviceUID.lowercased().contains(queryLower) {
                Log.info("🎤 Found microphone: \(deviceName) [\(deviceUID)] (id: \(did))")
                return did
            }
        }
        return 0
    }
    
    private func setSystemDefaultInput(deviceID: AudioDeviceID) {
        suppressDeviceChange = true
        var inputDeviceID = deviceID
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &inputDeviceID
        )
        if status != noErr {
            Log.info("⚠️ Failed to set system default input (error: \(status))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.suppressDeviceChange = false
        }
    }
    
    private func selectMicrophone(matching query: String) {
        if preferredDeviceID == 0 {
            preferredDeviceID = findInputDevice(matching: query)
        }
        
        guard preferredDeviceID != 0 else {
            Log.info("⚠️ Microphone matching '\(query)' not found, using system default")
            return
        }
        
        var currentDefault: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &currentDefault)
        
        if currentDefault != preferredDeviceID {
            Log.info("⚠️ System default changed — resetting to preferred mic")
            setSystemDefaultInput(deviceID: preferredDeviceID)
            Thread.sleep(forTimeInterval: 0.1)
        } else {
            Log.info("🎤 System default is correct (id: \(preferredDeviceID))")
        }
    }
    
    func startDeviceChangeListener() {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            
            guard !self.suppressDeviceChange else {
                Log.info("🔄 Audio input device changed (suppressed — our own change)")
                return
            }
            
            Log.info("🔄 Audio input device changed by system/user")
            
            if self.preferredDeviceID != 0 {
                Log.info("🔒 Re-locking system input to preferred mic")
                self.setSystemDefaultInput(deviceID: self.preferredDeviceID)
            }
            
            // Always restart engine on device change — the audio graph
            // may be corrupted regardless of whether we have a preferred mic.
            // If recording, stop it first (the recording is likely broken anyway).
            let wasRecording = self.isRecording
            if wasRecording {
                Log.info("⚠️ Device changed during recording — stopping to restart engine")
                DispatchQueue.main.async {
                    _ = self.stopRecording()
                }
            }
            
            DispatchQueue.global(qos: .userInitiated).async {
                // Let macOS settle the device change
                Thread.sleep(forTimeInterval: 0.5)
                self.restartEngine()
                if wasRecording {
                    Log.info("🔄 Device change recovery: engine restarted (was recording)")
                    DispatchQueue.main.async {
                        self.onDeviceChange?()
                    }
                }
            }
        }
        
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddress,
            DispatchQueue.main,
            listener
        )
        
        if status == noErr {
            self.deviceChangeListenerID = listener
            Log.info("👂 Listening for audio device changes")
        } else {
            Log.info("⚠️ Failed to add device change listener (error: \(status))")
        }
    }
    
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                Log.info("✅ Microphone permission granted")
            } else {
                Log.info("❌ Microphone permission denied")
            }
            completion(granted)
        }
    }
}
