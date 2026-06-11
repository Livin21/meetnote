import Foundation

/// Talks to LM Studio's OpenAI-compatible server on localhost. Everything
/// stays on this machine.
public struct LMStudio {
    public let baseURL: URL

    public init() {
        let raw = ProcessInfo.processInfo.environment["MEETNOTE_LMSTUDIO_URL"] ?? "http://localhost:1234"
        baseURL = URL(string: raw)!
    }

    public func listModels() throws -> [String] {
        let data = try get(path: "/v1/models")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            throw MeetnoteError("Unexpected /v1/models response from LM Studio.")
        }
        return models.compactMap { $0["id"] as? String }
    }

    /// Order of precedence: MEETNOTE_MODEL env var, then `preferred` (the
    /// app's picker choice) if it is still available, then the auto order
    /// below. Auto prefers the MoE gemma: benchmarked 2026-06-11, it wrote
    /// complete notes in 28s where qwen (a reasoning model) spent 149s
    /// thinking without emitting any.
    public func pickModel(preferred: String? = nil) throws -> String {
        if let forced = ProcessInfo.processInfo.environment["MEETNOTE_MODEL"], !forced.isEmpty {
            return forced
        }
        let models = try listModels().filter { !$0.lowercased().contains("embed") }
        guard !models.isEmpty else {
            throw MeetnoteError("LM Studio has no chat models available.")
        }
        if let preferred, !preferred.isEmpty, models.contains(preferred) {
            return preferred
        }
        for candidate in ["google/gemma-4-26b-a4b", "qwen/qwen3.6-27b"] {
            if models.contains(candidate) { return candidate }
        }
        return models[0]
    }

    /// Context size the model is actually loaded with, or nil if the model
    /// is not loaded (or the server doesn't expose it). LM Studio's JIT
    /// loading picks this per model config — never assume a fixed value.
    public func loadedContextLength(model: String) -> Int? {
        guard let data = try? get(path: "/api/v0/models"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return nil }
        guard let entry = entries.first(where: { ($0["id"] as? String) == model }),
              (entry["state"] as? String) == "loaded" else { return nil }
        return entry["loaded_context_length"] as? Int
    }

    /// Force a JIT load (1-token request) so loadedContextLength can be read.
    public func warmUp(model: String) {
        _ = try? chat(model: model, system: "Reply with OK.", user: "OK?", maxTokens: 1)
    }

    /// Make sure the model is loaded with at least `minimum` context, using
    /// the lms CLI to reload it if needed. Falls back to whatever context the
    /// server gives us when lms is unavailable. Returns the loaded context.
    public func ensureContext(model: String, minimum: Int) -> Int? {
        if let current = loadedContextLength(model: model), current >= minimum {
            return current
        }
        let lms = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".lmstudio/bin/lms").path
        if FileManager.default.isExecutableFile(atPath: lms) {
            runQuiet(lms, ["unload", model])
            runQuiet(lms, ["load", model, "--context-length", String(minimum), "-y"])
        } else {
            warmUp(model: model)
        }
        return loadedContextLength(model: model)
    }

    private func runQuiet(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    public func chat(model: String, system: String, user: String, maxTokens: Int = 4096) throws -> String {
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        let data = try post(path: "/v1/chat/completions", body: body, timeout: 900)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MeetnoteError("Unexpected chat response from LM Studio: \(String(data: data, encoding: .utf8) ?? "<binary>")")
        }
        if (choices.first?["finish_reason"] as? String) == "length", maxTokens > 1 {
            eprint("warning: \(model) hit the \(maxTokens)-token completion limit — output may be cut off (reasoning counts against it; a larger loaded context helps).")
        }
        return stripReasoning(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Thinking models (qwen) may emit <think>…</think> blocks; drop them.
    private func stripReasoning(_ text: String) -> String {
        guard let open = text.range(of: "<think>"),
              let close = text.range(of: "</think>") else { return text }
        var out = text
        out.removeSubrange(open.lowerBound..<close.upperBound)
        return out
    }

    private func get(path: String) throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = 5
        return try send(request)
    }

    private func post(path: String, body: [String: Any], timeout: TimeInterval) throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        return try send(request)
    }

    private func send(_ request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(MeetnoteError("No response."))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                result = .failure(MeetnoteError("No HTTP response from LM Studio."))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                result = .failure(MeetnoteError("LM Studio returned HTTP \(http.statusCode): \(bodyText.prefix(300))"))
                return
            }
            result = .success(data)
        }
        task.resume()
        semaphore.wait()
        return try result.get()
    }
}

public enum Summarizer {
    static var systemPrompt: String { """
    You are a precise meeting-notes writer. You receive a raw meeting transcript with \
    two speaker labels: "Me" (\(Config.ownerName), the note owner) and "Them" (everyone else on the \
    call, merged). Timestamps are HH:MM:SS from meeting start.

    Write concise, factual meeting notes in Markdown with exactly these sections:

    ## TL;DR
    2-4 bullets capturing what the meeting was about and what came out of it.

    ## Decisions
    Bullets for anything agreed or decided. Omit the section if none.

    ## Action items
    Checkboxes like `- [ ] owner — task`. Use real names when inferable from the \
    conversation, otherwise "Me"/"Them". Omit the section if none.

    ## Open questions
    Unresolved points or things to follow up. Omit the section if none.

    ## Discussion
    Short topic-by-topic recap with rough [HH:MM:SS] timestamps.

    Use a name for a participant only when that name is spoken in the transcript \
    (people addressing or introducing each other). If someone is never named, keep \
    the "Me"/"Them" labels — never guess or invent a name. If the transcript header \
    states "Other participants: …", those are the correct names and spellings — \
    attribute "Them" speech to them and prefer them over any transcribed variant \
    of a name (speech recognition regularly garbles names). Never invent facts that \
    are not in the transcript. Transcripts come from speech recognition and may \
    contain mis-heard words — when a term is obviously garbled, note the \
    uncertainty rather than guessing confidently.\(knownNamesHint)
    """ }

    /// Names are where speech recognition fails hardest; give the model the
    /// user's frequent collaborators so it can repair mishearings.
    static var knownNamesHint: String {
        let names = Config.knownNames
        guard !names.isEmpty else { return "" }
        return " Likely participants include: \(names.joined(separator: ", ")). " +
            "Speech recognition often mangles names — if a transcribed name looks " +
            "like a mishearing of one of these, use the known name instead."
    }

    static var mapPrompt: String { """
    Summarize this PART of a longer meeting transcript ("Me" = \(Config.ownerName), "Them" = \
    others; use names only when spoken in the transcript). Capture every decision, \
    action item (with owner and deadline), and open question, with timestamps. \
    Keep it under 250 words — it will be merged with the other parts.\(knownNamesHint)
    """ }

    /// Summarize a transcript, map-reducing if it is too long for one pass.
    /// Sizing adapts to the context the model is actually loaded with (read
    /// from LM Studio after a warm-up load): a 16k context single-passes a
    /// one-hour meeting; the 4k worst case map-reduces.
    public static func notes(transcript: String, lmstudio: LMStudio, model: String) throws -> String {
        // Aim for a context that single-passes the whole transcript (plus
        // room for the system prompt and a reasoning-inclusive completion),
        // capped to keep KV-cache memory bounded; 16k minimum covers ~1h.
        let targetContext = min(32_768, max(16_384, transcript.count / 3 + 3_800))
        let contextTokens = lmstudio.ensureContext(model: model, minimum: targetContext) ?? 4_096
        // Per-call input budget: leave ~3800 tokens for the system prompt and
        // the completion (which includes the model's reasoning), and assume a
        // conservative 3 chars per token for transcript text.
        let usableChars = max(6_000, (contextTokens - 3_800) * 3)
        if transcript.count <= usableChars {
            return try chat(lmstudio, model, contextTokens, systemPrompt, transcript)
        }
        let chunks = chunked(transcript, size: usableChars)
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            print("  Summarizing part \(index + 1)/\(chunks.count)…")
            let partial = try chat(lmstudio, model, contextTokens, mapPrompt, chunk)
            partials.append("--- Part \(index + 1)/\(chunks.count) ---\n" + partial)
        }
        return try reduce(partials, lmstudio: lmstudio, model: model, contextTokens: contextTokens, usableChars: usableChars)
    }

    /// Chat with a completion budget derived from the loaded context and the
    /// prompt size, so the model's reasoning can't starve the visible output.
    private static func chat(_ lmstudio: LMStudio, _ model: String, _ contextTokens: Int, _ system: String, _ user: String) throws -> String {
        let promptEstimate = (system.count + user.count) / 3
        let maxTokens = min(8_192, max(1_500, contextTokens - promptEstimate - 128))
        return try lmstudio.chat(model: model, system: system, user: user, maxTokens: maxTokens)
    }

    /// Merge partial summaries into final notes; if there are too many to fit
    /// one call, condense them pairwise first and recurse.
    private static func reduce(_ partials: [String], lmstudio: LMStudio, model: String, contextTokens: Int, usableChars: Int) throws -> String {
        let joined = partials.joined(separator: "\n\n")
        if joined.count <= usableChars || partials.count <= 2 {
            return try chat(
                lmstudio, model, contextTokens,
                systemPrompt + "\n\nYou are receiving partial summaries of consecutive parts of one meeting instead of the raw transcript. Merge them into one coherent set of notes; deduplicate items the recap repeated.",
                joined
            )
        }
        print("  Condensing \(partials.count) partial summaries…")
        var condensed: [String] = []
        var index = 0
        while index < partials.count {
            let group = partials[index..<min(index + 2, partials.count)].joined(separator: "\n\n")
            condensed.append(try chat(
                lmstudio, model, contextTokens,
                "Merge these consecutive partial meeting summaries into one, under 250 words. Preserve every decision, action item (owner, deadline), open question and timestamp; drop only filler.",
                group
            ))
            index += 2
        }
        return try reduce(condensed, lmstudio: lmstudio, model: model, contextTokens: contextTokens, usableChars: usableChars)
    }

    private static func chunked(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > size, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
