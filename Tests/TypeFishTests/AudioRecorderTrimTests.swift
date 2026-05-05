import AVFoundation
import XCTest
@testable import TypeFish

final class AudioRecorderTrimTests: XCTestCase {
    func testTrimTrailingSilencePreservesQuietSpeechAtEnd() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typefish_quiet_tail_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeSyntheticRecording(
            to: url,
            segments: [
                .tone(duration: 1.0, amplitude: 0.025),
                .silence(duration: 1.0),
                .tone(duration: 3.0, amplitude: 0.003),
                .silence(duration: 2.0),
            ]
        )

        let trimmedURL = try XCTUnwrap(AudioRecorder.trimTrailingSilence(fileURL: url))
        defer { try? FileManager.default.removeItem(at: trimmedURL) }

        let trimmedFile = try AVAudioFile(forReading: trimmedURL)
        let trimmedDuration = Double(trimmedFile.length) / trimmedFile.processingFormat.sampleRate

        XCTAssertGreaterThanOrEqual(trimmedDuration, 5.4)
        XCTAssertLessThan(trimmedDuration, 6.1)
    }

    func testTrimTrailingSilencePreservesRecentRealTruncationWhenAvailable() throws {
        let fixtureURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish/logs/audio/typefish_1777961170.wav")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Recent local truncation fixture is not available on this machine")
        }

        let originalFile = try AVAudioFile(forReading: fixtureURL)
        let originalDuration = Double(originalFile.length) / originalFile.processingFormat.sampleRate
        let trimmedURL = AudioRecorder.trimTrailingSilence(fileURL: fixtureURL)
        defer {
            if let trimmedURL {
                try? FileManager.default.removeItem(at: trimmedURL)
            }
        }

        let effectiveURL = trimmedURL ?? fixtureURL
        let effectiveFile = try AVAudioFile(forReading: effectiveURL)
        let effectiveDuration = Double(effectiveFile.length) / effectiveFile.processingFormat.sampleRate

        XCTAssertGreaterThanOrEqual(effectiveDuration, originalDuration - 1.1)
    }

    private enum Segment {
        case tone(duration: Double, amplitude: Float)
        case silence(duration: Double)

        var duration: Double {
            switch self {
            case let .tone(duration, _), let .silence(duration):
                return duration
            }
        }
    }

    private func writeSyntheticRecording(to url: URL, segments: [Segment]) throws {
        let sampleRate = 16_000.0
        let totalFrames = segments.reduce(into: 0) { total, segment in
            total += Int(segment.duration * sampleRate)
        }

        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        ))
        buffer.frameLength = AVAudioFrameCount(totalFrames)

        let channelData: UnsafePointer<UnsafeMutablePointer<Float>> = try XCTUnwrap(buffer.floatChannelData)
        let samples = channelData[0]
        var offset = 0
        for segment in segments {
            let frames = Int(segment.duration * sampleRate)
            switch segment {
            case let .tone(_, amplitude):
                for index in 0..<frames {
                    let phase = 2.0 * Double.pi * 220.0 * Double(index) / sampleRate
                    samples[offset + index] = Float(sin(phase)) * amplitude
                }
            case .silence:
                for index in 0..<frames {
                    samples[offset + index] = 0
                }
            }
            offset += frames
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
