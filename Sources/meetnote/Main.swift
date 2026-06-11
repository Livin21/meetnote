import Foundation
import MeetnoteCore

@main
struct Main {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.isEmpty ? "help" : args.removeFirst()
        do {
            switch command {
            case "start":
                try await runStart(args)
            case "summarize":
                try runSummarize(args)
            case "doctor":
                await runDoctor()
            case "help", "--help", "-h":
                printUsage()
            default:
                printUsage()
                throw MeetnoteError("Unknown command: \(command)")
            }
        } catch {
            eprint("error: \(error)")
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        meetnote — local meeting transcription + notes (everything stays on this Mac)

        usage:
          meetnote start [topic words…] [--with "Asha, Ben"] [--no-summary]
                         [--locale en_IN] [--max-hours 4]
              Record mic + system audio, transcribe on-device, Ctrl-C to stop.
              On stop, writes a transcript and (unless --no-summary) notes
              summarized by your local LM Studio model. --with names the other
              participants so notes never rely on misheard names.

          meetnote summarize <transcript.md> [topic words…]
              (Re)generate notes from an existing transcript via LM Studio.

          meetnote doctor
              Check permissions, speech model, LM Studio, and output paths.

        env overrides (each falls back to the MeetNote app's panel settings):
          MEETNOTE_DIR           output dir   (default ~/Documents/MeetNote)
          MEETNOTE_OWNER         your name, used as "Me" in notes
          MEETNOTE_LMSTUDIO_URL  server       (default http://localhost:1234)
          MEETNOTE_MODEL         model id     (auto: gemma-4-26b-a4b → qwen → first chat model)
        """)
    }

    // MARK: - start

    static func runStart(_ rawArgs: [String]) async throws {
        var noSummary = false
        var localeID = "en_IN"
        var maxHours = 4.0
        var topicWords: [String] = []
        var participants: [String] = []
        var iterator = rawArgs.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--no-summary": noSummary = true
            case "--locale": localeID = iterator.next() ?? localeID
            case "--max-hours": maxHours = Double(iterator.next() ?? "") ?? maxHours
            case "--with":
                participants = (iterator.next() ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            default: topicWords.append(arg)
            }
        }
        let topic = slugify(topicWords)
        let locale = Locale(identifier: localeID)
        let store = Store()
        try store.prepare()

        let recorder = Recorder()
        print("Starting capture (mic + system audio)…")
        try await recorder.start(locale: locale)
        let startedAt = recorder.startedAt ?? Date()
        print("""
        ● Recording "\(topic)" — transcribing on-device. Press Ctrl-C to stop.
        """)

        await waitForStop(maxSeconds: maxHours * 3600)

        print("\nStopping, finalizing transcription…")
        let segments = await recorder.stop()
        guard !segments.isEmpty else {
            throw MeetnoteError("No speech was transcribed — nothing to save. (Check `meetnote doctor` if this is unexpected.)")
        }
        let transcriptURL = try store.writeTranscript(topic: topic, startedAt: startedAt, segments: segments, participants: participants)
        print("Transcript: \(transcriptURL.path) (\(segments.count) segments)")

        if noSummary {
            print("Skipping summary (--no-summary). Later: meetnote summarize \(transcriptURL.path)")
            return
        }
        do {
            let notesURL = try summarize(transcriptURL: transcriptURL, topic: topic, startedAt: startedAt, store: store)
            print("Notes: \(notesURL.path)")
        } catch {
            eprint("""
            Summarization failed (\(error)).
            The transcript is safe. Start LM Studio's server (`lms server start`, load a model) and run:
              meetnote summarize \(transcriptURL.path)
            """)
        }
    }

    /// Wait for Ctrl-C, or the safety timeout, whichever comes first.
    static func waitForStop(maxSeconds: Double) async {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        for source in [sigint, sigterm] {
            source.setEventHandler { continuation.yield(()) }
            source.resume()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream { break }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(maxSeconds))
                if !Task.isCancelled {
                    print("\nReached --max-hours safety limit; stopping.")
                }
            }
            await group.next()
            group.cancelAll()
        }
        sigint.cancel()
        sigterm.cancel()
    }

    // MARK: - summarize

    static func runSummarize(_ args: [String]) throws {
        guard let path = args.first else {
            throw MeetnoteError("usage: meetnote summarize <transcript.md> [topic words…]")
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let transcript = try String(contentsOf: url, encoding: .utf8)
        let topicWords = Array(args.dropFirst())
        let topic = topicWords.isEmpty
            ? topicFromTranscriptName(url) : slugify(topicWords)
        let startedAt = (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date)
            .flatMap { $0 } ?? Date()
        let store = Store()
        try store.prepare()
        let notesURL = try summarize(transcriptURL: url, topic: topic, startedAt: startedAt, store: store, transcript: transcript)
        print("Notes: \(notesURL.path)")
    }

    static func summarize(
        transcriptURL: URL,
        topic: String,
        startedAt: Date,
        store: Store,
        transcript: String? = nil
    ) throws -> URL {
        let text = try transcript ?? String(contentsOf: transcriptURL, encoding: .utf8)
        let lmstudio = LMStudio()
        let model = try lmstudio.pickModel(preferred: Config.preferredModel)
        print("Summarizing with local model \(model) (LM Studio)…")
        let body = try Summarizer.notes(transcript: text, lmstudio: lmstudio, model: model)
        return try store.writeNotes(topic: topic, startedAt: startedAt, body: body, transcriptURL: transcriptURL, model: model)
    }

    // MARK: - doctor

    static func runDoctor() async {
        print("meetnote doctor\n")

        let store = Store()
        do {
            try store.prepare()
            print("✓ Output dir: \(store.meetingsDir.path)")
        } catch {
            print("✗ Output dir \(store.meetingsDir.path): \(error)")
        }

        do {
            try await MicCapture.ensurePermission()
            print("✓ Microphone permission granted")
        } catch {
            print("✗ Microphone: \(error)")
        }

        do {
            let locale = Locale(identifier: "en_IN")
            try await TranscriptionPipeline.ensureModel(locale: locale)
            print("✓ On-device speech model installed (en_IN)")
        } catch {
            print("✗ Speech model: \(error)")
        }

        do {
            print("  (playing a short test sound…)")
            let heard = try await SetupCheck.tapTestPeak()
            if heard > 0.001 {
                print("✓ System-audio tap captures audio (test-sound peak \(heard))")
            } else {
                print("""
                ✗ System-audio tap is delivering SILENCE — the System Audio Recording \
                permission is missing for the app you launched this from (your terminal).
                  Fix: \(SetupCheck.grantHint) Then run doctor again.
                """)
            }
        } catch {
            print("✗ System-audio tap: \(error)")
        }

        let lmstudio = LMStudio()
        do {
            let models = try lmstudio.listModels()
            let model = try lmstudio.pickModel(preferred: Config.preferredModel)
            print("✓ LM Studio reachable at \(lmstudio.baseURL) — \(models.count) model(s), will use: \(model)")
        } catch {
            print("✗ LM Studio at \(lmstudio.baseURL): \(error)")
            print("  → start it with: lms server start   (then load a model in LM Studio)")
        }
    }
}
