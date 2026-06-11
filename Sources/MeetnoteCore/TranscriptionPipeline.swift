import AVFoundation
import CoreMedia
import Foundation
import Speech

/// One on-device speech-to-text stream (Apple SpeechAnalyzer / SpeechTranscriber,
/// macOS 26+). The recorder runs two of these: one for the mic ("Me"), one for
/// the system-audio tap ("Them").
public final class TranscriptionPipeline {
    let label: String
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private let onSegment: (Segment) -> Void

    init(label: String, locale: Locale, onSegment: @escaping (Segment) -> Void) {
        self.label = label
        self.onSegment = onSegment
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],          // final results only
            attributeOptions: [.audioTimeRange]
        )
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    /// Make sure the on-device model for `locale` is installed (one-time download).
    public static func ensureModel(locale: Locale) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            let ids = supported.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
            throw MeetnoteError("Locale \(locale.identifier) is not supported for on-device transcription. Supported: \(ids)")
        }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return }

        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            print("Downloading the on-device speech model for \(locale.identifier) (one-time)…")
            try await request.downloadAndInstall()
            print("Speech model installed.")
        }
    }

    func start() async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MeetnoteError("No compatible audio format for the on-device transcriber (\(label)).")
        }
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = result.range.start.seconds
                    self.onSegment(Segment(label: self.label, start: start.isFinite ? start : 0, text: text))
                }
            } catch {
                eprint("[\(self.label)] transcriber stream ended with error: \(error)")
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    private let debug = ProcessInfo.processInfo.environment["MEETNOTE_DEBUG"] != nil
    private var feedCount = 0

    /// Called from the audio capture thread. Converts to the analyzer's
    /// format (which also copies the buffer) and feeds it in.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let format = analyzerFormat, let continuation = inputContinuation else { return }
        do {
            let converted = try convert(buffer, to: format)
            if debug {
                feedCount += 1
                if feedCount == 1 || feedCount % 300 == 0 {
                    eprint("[\(label)] feed #\(feedCount): in \(buffer.frameLength)f peak \(peakAmplitude(buffer)) → out \(converted.frameLength)f (analyzer fmt \(format))")
                }
            }
            guard converted.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        } catch {
            if debug { eprint("[\(label)] convert error: \(error)") }
        }
    }


    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            eprint("[\(label)] finalize failed: \(error)")
        }
        await resultsTask?.value
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else {
            throw MeetnoteError("Cannot convert \(buffer.format) → \(format).")
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw MeetnoteError("Could not allocate conversion buffer.")
        }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw conversionError ?? MeetnoteError("Audio conversion failed.")
        }
        return output
    }
}
