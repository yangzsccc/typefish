import AVFoundation

/// Records microphone audio to a file using AVAudioEngine.
/// Outputs 16kHz mono WAV (optimal for Whisper).
class AudioRecorder {
    
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private(set) var isRecording = false
    
    /// Start recording microphone to a temporary file
    func startRecording() -> Bool {
        guard !isRecording else { return false }
        
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
