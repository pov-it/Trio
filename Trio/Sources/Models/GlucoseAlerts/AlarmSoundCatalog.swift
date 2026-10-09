import Foundation

/// Catalog of the bundled critical-alarm sound files (`Trio/Resources/Sounds/`).
/// Ported from Loop's audio-critical-alerts branch. Single source of truth
/// for the alarm sound picker.
enum AlarmSoundCatalog {
    /// Stored in `soundFilename` to mean "the iOS notification sound": non-critical
    /// notifications use `UNNotificationSound.default`, critical ones
    /// `UNNotificationSound.defaultCritical`. No file extension, so builds that
    /// predate this option resolve it as a missing file and still fall back to
    /// the iOS default sound.
    static let systemDefault = "system_default"

    /// Bundled tone used where iOS offers no system notification sound: the
    /// AlarmKit alarm and the in-process `CriticalAlertAudioPlayer`, which only
    /// run when Critical Alerts are not authorized. AlarmKit's own default is
    /// the Clock alarm tone, which is harsher than the notification sound this
    /// option stands in for, so a soft bundled tone is used instead.
    static let systemDefaultBundledFallback = "bloom.caf"

    /// (filename, displayName) tuples in display order.
    private static let catalog: [(filename: String, displayName: String)] = [
        ("urgent_low.caf", String(localized: "Urgent Low")),
        ("critical.caf", String(localized: "Critical")),
        ("alarm.caf", String(localized: "Alarm")),
        ("bright_alarm.caf", String(localized: "Bright Alarm")),
        ("honk.caf", String(localized: "Honk")),
        ("trill.caf", String(localized: "Trill")),
        ("chime.caf", String(localized: "Chime")),
        ("clear_chimes.caf", String(localized: "Clear Chimes")),
        ("high_chimes.caf", String(localized: "High Chimes")),
        ("dings.caf", String(localized: "Dings")),
        ("bloom.caf", String(localized: "Bloom")),
        ("bloop.caf", String(localized: "Bloop")),
        ("spring.caf", String(localized: "Spring")),
        ("minimal.caf", String(localized: "Minimal")),
        ("simple.caf", String(localized: "Simple")),
        ("synth.caf", String(localized: "Synth")),
        ("mood_synth.caf", String(localized: "Mood Synth")),
        ("crying.caf", String(localized: "Crying"))
    ]

    /// Bundled `.caf` files only. Every entry must exist at the main bundle root.
    static let allFilenames: [String] = catalog.map(\.filename)

    /// Everything the tone picker offers, system default first.
    static let pickerOptions: [String] = [systemDefault] + allFilenames

    static func isSystemDefault(_ filename: String) -> Bool {
        filename == systemDefault
    }

    /// The bundled file to play for `filename` on channels that can only play
    /// a file from the app bundle.
    static func bundledFilename(for filename: String) -> String {
        isSystemDefault(filename) ? systemDefaultBundledFallback : filename
    }

    static func displayName(for filename: String) -> String {
        if isSystemDefault(filename) {
            return String(localized: "System default", comment: "Alarm tone option that uses the standard iOS notification sound")
        }
        return catalog.first { $0.filename == filename }?.displayName ?? filename
    }
}
