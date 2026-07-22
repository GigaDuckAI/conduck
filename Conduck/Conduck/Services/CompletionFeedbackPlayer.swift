import AudioToolbox

#if os(macOS)
import AppKit
#endif

/// Plays completion feedback (sound, haptic, or both) when transcription completes.
/// Uses AudioToolbox exclusively — works from background App Intent context.
/// iPad/macOS only support sound (no haptic motor).
enum CompletionFeedbackPlayer {
    private static let soundID: SystemSoundID = {
        guard let url = Bundle.main.url(forResource: "complete", withExtension: "wav") else { return 0 }
        var id: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(url as CFURL, &id)
        return id
    }()

    /// Execute completion feedback based on the user's preference.
    /// - Parameter mode: "off", "sound", "rumble", or "both"
    static func play(mode: String) {
        switch mode {
        case "sound":
            playSound()
        case "rumble":
            playHaptic()
        case "both":
            playSound()
            playHaptic()
        default:
            break
        }
    }

    private static func playSound() {
        #if os(macOS)
        if let url = Bundle.main.url(forResource: "complete", withExtension: "wav") {
            NSSound(contentsOf: url, byReference: true)?.play()
        }
        #else
        guard soundID != 0 else { return }
        AudioServicesPlaySystemSound(soundID)
        #endif
    }

    static func playHaptic() {
        #if os(iOS)
        // kSystemSoundID_Vibrate: documented public constant, works from background
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        #endif
    }
}
