import AVFoundation
import Foundation

/// Captures the default microphone via AVAudioEngine.
public final class MicCapture {
    private let engine = AVAudioEngine()

    public static func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw MeetnoteError("Microphone access was denied. Grant it in System Settings → Privacy & Security → Microphone.")
            }
        default:
            throw MeetnoteError("Microphone access is denied or restricted. Grant it in System Settings → Privacy & Security → Microphone.")
        }
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetnoteError("No usable microphone input format (got \(format)).")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
