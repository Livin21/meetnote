import AVFoundation
import Foundation

/// Orchestrates a recording session: mic + system tap, each feeding its own
/// on-device transcription pipeline, segments merged by timestamp.
public final class Recorder {
    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private var micPipeline: TranscriptionPipeline?
    private var systemPipeline: TranscriptionPipeline?
    public let collector = SegmentCollector()
    public private(set) var startedAt: Date?

    public init() {}

    public func start(locale: Locale) async throws {
        try await MicCapture.ensurePermission()
        try await TranscriptionPipeline.ensureModel(locale: locale)

        let collector = self.collector
        let micPipeline = TranscriptionPipeline(label: "Me", locale: locale) { collector.add($0) }
        let systemPipeline = TranscriptionPipeline(label: "Them", locale: locale) { collector.add($0) }
        try await micPipeline.start()
        try await systemPipeline.start()
        self.micPipeline = micPipeline
        self.systemPipeline = systemPipeline

        // Start system tap first (it may show a one-time permission prompt).
        try system.start { [weak systemPipeline] buffer in
            systemPipeline?.feed(buffer)
        }
        try mic.start { [weak micPipeline] buffer in
            micPipeline?.feed(buffer)
        }
        startedAt = Date()
    }

    /// Stops capture, drains both transcribers, returns merged segments.
    public func stop() async -> [Segment] {
        mic.stop()
        system.stop()
        await micPipeline?.finish()
        await systemPipeline?.finish()
        return collector.sorted()
    }
}
