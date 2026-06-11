import Foundation

/// Settings shared by the CLI and the menu bar app. Resolution order:
/// environment variable → shared defaults suite (written by the app's
/// panel) → neutral default. The suite lives at
/// ~/Library/Preferences/dev.livin.meetnote.shared.plist so both binaries
/// see the same values despite having different bundle identifiers.
public enum Config {
    public static let suiteName = "dev.livin.meetnote.shared"
    public static let shared = UserDefaults(suiteName: suiteName)!

    /// Where notes and transcripts land.
    public static var outputDir: URL {
        if let env = ProcessInfo.processInfo.environment["MEETNOTE_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: NSString(string: env).expandingTildeInPath)
        }
        if let stored = shared.string(forKey: "outputDir"), !stored.isEmpty {
            return URL(fileURLWithPath: NSString(string: stored).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/MeetNote")
    }

    /// The note owner's name — what the summarizer calls "Me".
    public static var ownerName: String {
        if let env = ProcessInfo.processInfo.environment["MEETNOTE_OWNER"], !env.isEmpty {
            return env
        }
        if let stored = shared.string(forKey: "ownerName"), !stored.isEmpty {
            return stored
        }
        let account = NSFullUserName()
        return account.isEmpty ? "the note owner" : account
    }

    /// Frequent collaborators' names — given to the summarizer as a hint so
    /// it can correct names the speech recognizer misheard.
    public static var knownNames: [String] {
        let raw = ProcessInfo.processInfo.environment["MEETNOTE_NAMES"]
            ?? shared.string(forKey: "knownNames") ?? ""
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The model picked in the app's panel; nil means auto.
    public static var preferredModel: String? {
        guard let stored = shared.string(forKey: "modelID"), !stored.isEmpty else { return nil }
        return stored
    }
}
