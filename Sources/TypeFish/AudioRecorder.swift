import AVFoundation

/// Records microphone audio to a file using AVAudioEngine.
/// Outputs 16kHz mono WAV (optimal for Whisper).
/// Tracks peak audio level to detect silence.
class AudioRecorder {
    
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private(set) var isRecording = false
    
    /// Peak RMS level during recording (0.0 = silence, 1.0 = max)
    private(set) var peakRMSLevel: Float = 0.0
    
    /// Start recording microphone to a temporary file
    func startRecording() -> Bool {
        guard !isRecording else { return false }
        
        peakRMSLevel = 0.0
        
        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "typefish_\(Int(Date().timeIntervalSince1970)).wav"
        let url = tempDir.appendingPathComponent(filename)
        self.outputURL = url
        
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
        
        if needsConversion {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self, let file = self.audioFile else { return }
                
                // Track audio level
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
                    do {
                        try file.write(from: convertedBuffer)
                    } catch {
                        Log.info("⚠️ Failed to write audio: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self, let file = self.audioFile else { return }
                self.updatePeakLevel(buffer: buffer)
                do {
                    try file.write(from: buffer)
                } catch {
                    Log.info("⚠️ Failed to write audio: \(error.localizedDescription)")
                }
            }
        }
        
        do {
            try audioEngine.start()
            isRecording = true
            Log.info("🎙️ Recording started → \(url.lastPathComponent)")
            return true
        } catch {
            Log.info("❌ Audio engine failed to start: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
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
