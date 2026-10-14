import CoreAudio
import Foundation

public struct AudioActivity: Equatable, Sendable {
    public var input = false
    public var output = false

    public init(input: Bool = false, output: Bool = false) {
        self.input = input
        self.output = output
    }
}

public enum AudioProcessFinder {
    /// Chrome plays meeting audio from helper processes (e.g. the audio
    /// service), so matching must be by bundle identifier prefix over the
    /// HAL process list instead of translating the main app PID.
    public static func matchesChrome(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID.lowercased().hasPrefix("com.google.chrome")
    }

    public static func chromeAudioObjects() -> [AudioObjectID] {
        guard let list = try? CoreAudioSupport.readProcessObjectList() else { return [] }
        return list.filter { matchesChrome(bundleID: CoreAudioSupport.readBundleID(of: $0)) }
    }

    /// Whether Chrome currently holds the microphone and/or plays audio. An
    /// open input stream is how a Meet call shows up to Core Audio.
    public static func chromeActivity() -> AudioActivity {
        var activity = AudioActivity()
        for object in chromeAudioObjects() {
            if (CoreAudioSupport.readUInt32(kAudioProcessPropertyIsRunningInput, of: object) ?? 0) != 0 {
                activity.input = true
            }
            if (CoreAudioSupport.readUInt32(kAudioProcessPropertyIsRunningOutput, of: object) ?? 0) != 0 {
                activity.output = true
            }
        }
        return activity
    }

    public static func currentProcessAudioObject() -> AudioObjectID? {
        CoreAudioSupport.translatePIDToProcessObject(ProcessInfo.processInfo.processIdentifier)
    }
}
