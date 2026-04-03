import Foundation
import AVFoundation

/// Compresses WAV audio to M4A (AAC) for faster uploads.
/// M4A is natively supported by macOS and Groq's Whisper API.
/// Typical compression: 2MB WAV → ~200KB M4A (10x reduction).
enum AudioCompressor {
    
    /// Compress a WAV file to M4A. Returns the compressed file URL, or nil on failure.
    /// On failure, returns the original WAV URL so transcription can proceed.
    static func compressToM4A(wavURL: URL) -> URL? {
        let startTime = CFAbsoluteTimeGetCurrent()
        let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
        
        // Remove existing m4a if present
        try? FileManager.default.removeItem(at: m4aURL)
        
        guard let asset = try? AVAudioFile(forReading: wavURL) else {
            Log.info("⚠️ Compress: cannot read WAV file")
            return nil
        }
        
        let inputFormat = asset.processingFormat
        let frameCount = AVAudioFrameCount(asset.length)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            Log.info("⚠️ Compress: cannot create buffer")
            return nil
        }
        
        do {
            try asset.read(into: buffer)
        } catch {
            Log.info("⚠️ Compress: cannot read audio data: \(error.localizedDescription)")
            return nil
        }
        
        // Set up output format: AAC, mono, same sample rate
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,  // 32kbps — good enough for speech
        ]
        
        guard let outputFile = try? AVAudioFile(
            forWriting: m4aURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) else {
            Log.info("⚠️ Compress: cannot create output file")
            return nil
        }
        
        do {
            try outputFile.write(from: buffer)
        } catch {
            Log.info("⚠️ Compress: cannot write M4A: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: m4aURL)
            return nil
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let wavSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int) ?? 0
        let m4aSize = (try? FileManager.default.attributesOfItem(atPath: m4aURL.path)[.size] as? Int) ?? 0
        let ratio = wavSize > 0 ? Double(wavSize) / Double(max(m4aSize, 1)) : 0
        
        Log.info("🗜️ Compressed: \(wavSize/1024)KB → \(m4aSize/1024)KB (\(String(format: "%.1f", ratio))x, \(String(format: "%.2f", elapsed))s)")
        
        return m4aURL
    }
}
