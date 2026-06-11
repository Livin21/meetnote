import Foundation

/// Where transcripts and notes land (see Config.outputDir).
public struct Store {
    public let meetingsDir: URL
    public let transcriptsDir: URL

    public init() {
        meetingsDir = Config.outputDir
        transcriptsDir = meetingsDir.appending(path: "transcripts")
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
    }

    public func writeTranscript(topic: String, startedAt: Date, segments: [Segment], participants: [String] = []) throws -> URL {
        let day = Self.dayStamp(startedAt)
        let time = Self.timeStamp(startedAt)
        let url = unique(in: transcriptsDir, base: "\(day)-\(time)-\(topic)")
        var lines: [String] = [
            "# Transcript — \(day) \(time) — \(topic)",
            "",
            "Recorded on-device by meetnote. \"Me\" = mic (\(Config.ownerName)), \"Them\" = system audio (everyone else on the call).",
        ]
        if !participants.isEmpty {
            lines.append("Other participants: \(participants.joined(separator: ", ")).")
        }
        lines.append("")
        for segment in segments {
            lines.append("[\(SegmentCollector.clock(segment.start))] \(segment.label): \(segment.text)")
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public func writeNotes(topic: String, startedAt: Date, body: String, transcriptURL: URL, model: String?) throws -> URL {
        let day = Self.dayStamp(startedAt)
        let url = unique(in: meetingsDir, base: "\(day)-\(topic)")
        let provenance = model.map { "on-device transcript + local model `\($0)` via LM Studio" }
            ?? "on-device transcript (notes written manually or pending)"
        let content = """
        # Meeting notes — \(day) — \(topic)

        > \(provenance) · raw transcript: [\(transcriptURL.lastPathComponent)](transcripts/\(transcriptURL.lastPathComponent))

        \(body)
        """
        try content.appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func unique(in dir: URL, base: String) -> URL {
        var candidate = dir.appending(path: base + ".md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appending(path: "\(base)-\(counter).md")
            counter += 1
        }
        return candidate
    }

    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func timeStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmm"
        return formatter.string(from: date)
    }
}
