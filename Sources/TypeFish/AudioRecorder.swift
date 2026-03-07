import AVFoundation
import ObjCExceptionCatcher

/// Records microphone audio to a file using AVAudioEngine.
/// Outputs 16kHz mono WAV (optimal for Whisper).
/// Tracks peak audio level to detect silence.
class AudioRecorder {
    
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private(set) var isRecording = false
    
    /// Preferred microphone identifier (partial match on ID or name)
    var preferredMicrophone: String? = nil
    
    /// Peak RMS level during recording (0.0 = silence, 1.0 = max)
    private(set) var peakRMSLevel: Float = 0.0
    
    /// Real-time audio level callback (called on audio thread)
    var onAudioLevel: ((Float) -> Void)?
    
    /// Start recording microphone to a temporary file
    func startRecording() -> Bool {
        guard !isRecording else { return false }
        
        peakRMSLevel = 0.0
        
        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "typefish_\(Int(Date().timeIntervalSince1970)).wav"
        let url = tempDir.appendingPathComponent(filename)
        self.outputURL = url
        
        // Reset engine to pick up any device changes (prevents crash on device switch)
        audioEngine.reset()
        
        // Select preferred microphone if configured
        if let pref = preferredMicrophone, !pref.isEmpty {
            selectMicrophone(matching: pref)
        }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard inputFormat.sampleRate > 0 else {
            Log.info("❌ No microphone input available")
            return false
        }
        
        // Target format: 16kHz mono (Whisper's native rate)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            Log.info("❌ Failed to create target audio format")
            return false
        }
        
        // Create audio file
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: targetFormat.settings)
        } catch {
            Log.info("❌ Failed to create audio file: \(error.localizedDescription)")
            return false
        }
        
        // Install converter tap if sample rates differ
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Log.info("❌ Failed to create audio converter")
            return false
        }
        
        let needsConversion = inputFormat.sampleRate != 16000 || inputFormat.channelCount != 1
        
        // Install tap — use ObjC exception catcher since installTap throws NSException
        // on device format mismatch (e.g. after headphone connect/disconnect)
        if !installTapSafely(on: inputNode, format: inputFormat, targetFormat: targetFormat, converter: converter) {
            // Retry: full reset and re-read format
            Log.info("⚠️ Tap install failed, retrying with engine reset...")
            audioEngine.reset()
            
            if let pref = preferredMicrophone, !pref.isEmpty {
                selectMicrophone(matching: pref)
            }
            
            let retryNode = audioEngine.inputNode
            let retryFormat = retryNode.outputFormat(forBus: 0)
            guard retryFormat.sampleRate > 0 else {
                Log.info("❌ No microphone available after reset")
                return false
            }
            guard let retryConverter = AVAudioConverter(from: retryFormat, to: targetFormat) else {
                Log.info("❌ Failed to create converter on retry")
                return false
            }
            
            if !installTapSafely(on: retryNode, format: retryFormat, targetFormat: targetFormat, converter: retryConverter) {
                Log.info("❌ Tap install failed on retry too")
                return false
            }
        }
        
        do {
            try audioEngine.start()
            isRecording = true
            Log.info("🎙️ Recording started → \(url.lastPathComponent)")
            return true
        } catch {
            Log.info("❌ Audio engine failed to start: \(error.localizedDescription)")
            audioEngine.inputNode.removeTap(onBus: 0)
            return false
        }
    }
    
    /// Stop recording and return the file URL
    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioFile = nil
        isRecording = false
        
        guard let url = outputURL else { return nil }
        
        // Check file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            Log.info("🎙️ Recording stopped: \(size / 1024)KB")
        }
        
        return url
    }
    
    /// Check if audio was basically silence (Whisper hallucination prevention)
    /// Returns true if peak RMS was below threshold
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
                    guard let self = self, let file = self.audioFile else { return }
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
                    guard let self = self, let file = self.audioFile else { return }
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
    /// Scans from the end, finds last frame above threshold, keeps 500ms buffer after it.
    static func trimTrailingSilence(fileURL: URL, threshold: Float = 0.008) -> URL? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return nil }
        
        // Read entire file into buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        
        guard let channelData = buffer.floatChannelData else { return nil }
        let data = channelData[0]
        let sampleRate = Int(format.sampleRate)
        
        // Scan backwards in chunks of 50ms to find last speech
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
        
        // Add 500ms buffer after last speech
        let bufferFrames = sampleRate / 2
        let trimFrame = min(lastSpeechFrame + bufferFrames, Int(totalFrames))
        
        // Only trim if we'd remove at least 1 second
        let removedFrames = Int(totalFrames) - trimFrame
        guard removedFrames > sampleRate else { return nil }  // less than 1s silence, don't bother
        
        let removedMs = removedFrames * 1000 / sampleRate
        Log.info("✂️ Trimmed \(removedMs)ms trailing silence")
        
        // Write trimmed audio to new file
        let trimmedURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("trimmed_\(fileURL.lastPathComponent)")
        
        guard let trimmedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(trimFrame)) else { return nil }
        // Copy frames
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
    
    /// Select a specific microphone by partial match on ID or name
    private func selectMicrophone(matching query: String) {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        // Get all audio devices
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
            // Check if device has input channels
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
            
            // Get device name
            var nameProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(did, &nameProperty, 0, nil, &nameSize, &name)
            let deviceName = name as String
            
            // Get device UID
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
                deviceID = did
                Log.info("🎤 Selected microphone: \(deviceName) [\(deviceUID)]")
                break
            }
        }
        
        guard deviceID != 0 else {
            Log.info("⚠️ Microphone matching '\(query)' not found, using system default")
            return
        }
        
        // Set as system default input (affects AVAudioEngine's inputNode)
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
            Log.info("⚠️ Failed to set input device (error: \(status))")
        }
    }
    
    /// Request microphone permission
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
