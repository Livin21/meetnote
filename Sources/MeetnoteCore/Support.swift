import AVFoundation
import Foundation

public struct MeetnoteError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// One finalized utterance from one of the two audio streams.
public struct Segment {
    public let label: String          // "Me" or "Them"
    public let start: TimeInterval    // seconds from recording start
    public let text: String

    public init(label: String, start: TimeInterval, text: String) {
        self.label = label
        self.start = start
        self.text = text
    }
}

/// Thread-safe accumulator; audio/recognition callbacks land here.
public final class SegmentCollector {
    private let lock = NSLock()
    private var segments: [Segment] = []
    public var live = true                       // print segments as they arrive
    public var onAdd: ((Segment) -> Void)?       // UI observer (called off-main)

    public init() {}

    public func add(_ segment: Segment) {
        lock.lock()
        segments.append(segment)
        lock.unlock()
        if live {
            print("  [\(Self.clock(segment.start))] \(segment.label): \(segment.text)")
        }
        onAdd?(segment)
    }

    public func sorted() -> [Segment] {
        lock.lock(); defer { lock.unlock() }
        return segments.sorted { $0.start < $1.start }
    }

    public static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

public func slugify(_ words: [String]) -> String {
    let joined = words.joined(separator: " ").lowercased()
    let allowed = CharacterSet.alphanumerics
    var out = ""
    var lastDash = true
    for scalar in joined.unicodeScalars {
        if allowed.contains(scalar) {
            out.unicodeScalars.append(scalar)
            lastDash = false
        } else if !lastDash {
            out.append("-")
            lastDash = true
        }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "meeting" : out
}

/// "2026-06-11-1430-weekly-sync.md" → "weekly-sync"
public func topicFromTranscriptName(_ url: URL) -> String {
    let stem = url.deletingPathExtension().lastPathComponent
    let parts = stem.split(separator: "-")
    if parts.count > 4 {
        return parts.dropFirst(4).joined(separator: "-")
    }
    return stem
}

public func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Max absolute sample value; works for interleaved and deinterleaved float buffers.
public func peakAmplitude(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData else { return -1 }
    var maxAbs: Float = 0
    let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
    let samples = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
    for ch in 0..<channels {
        for i in 0..<samples {
            maxAbs = max(maxAbs, abs(data[ch][i]))
        }
    }
    return maxAbs
}
