import Foundation

public enum SetupCheck {
    /// Creating a tap succeeds even without the System Audio Recording TCC
    /// grant — macOS then just delivers silence. So play a real sound through
    /// system output and return the peak amplitude the tap heard. ~0 means
    /// the permission is missing for the responsible app.
    public static func tapTestPeak() async throws -> Float {
        let tap = SystemAudioCapture()
        let lock = NSLock()
        var peak: Float = 0
        try tap.start { buffer in
            let p = peakAmplitude(buffer)
            lock.lock()
            peak = max(peak, p)
            lock.unlock()
        }
        defer { tap.stop() }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Glass.aiff"]
        try player.run()
        player.waitUntilExit()
        try? await Task.sleep(for: .milliseconds(400))
        return lock.withLock { peak }
    }

    public static let grantHint = """
    System Settings → Privacy & Security → Screen & System Audio Recording → \
    "System Audio Recording Only" → + → add the app, enable it.
    """

    public static let settingsPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
