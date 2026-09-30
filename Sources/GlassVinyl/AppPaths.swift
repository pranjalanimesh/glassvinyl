import Foundation

/// Where GlassVinyl keeps its data: ~/Library/Application Support/GlassVinyl
/// (listening log, library copy, recommendations, karaoke tools and tracks).
enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("GlassVinyl", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The app was called YTPlayer before its first public release. Moves that version's
    /// data folder and settings over once, so nothing has to be downloaded or set again.
    static func migrateFromYTPlayer() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("YTPlayer", isDirectory: true)
        let new = base.appendingPathComponent("GlassVinyl", isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }

        let defaults = UserDefaults.standard
        let marker = "migratedFromYTPlayer"
        guard !defaults.bool(forKey: marker) else { return }
        // Only the old app's own keys; a suite's dictionaryRepresentation would include global ones.
        let oldDomain = "com.pranjal.ytplayer" as CFString
        if let keys = CFPreferencesCopyKeyList(oldDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
           let values = CFPreferencesCopyMultiple(keys as CFArray, oldDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] {
            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }
}
