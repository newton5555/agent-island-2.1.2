import Foundation

/// One-shot rename of persisted preference keys from the inherited
/// "MacIsland." prefix to "AgentIsland.". Copy-then-delete keeps the pass
/// idempotent, preserves every user setting (thresholds, language, cost
/// cache, provider toggles), and leaves no legacy keys on disk.
///
/// Must run before any store singleton reads UserDefaults — stores capture
/// their value in `init`, so this is called from `AgentIslandApp.init()`,
/// which precedes both the scene build and `applicationDidFinishLaunching`.
enum LegacyPrefsMigrator {
    static func run(defaults: UserDefaults = .standard) {
        let legacyPrefix = "MacIsland."
        let newPrefix = "AgentIsland."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(legacyPrefix) {
            let newKey = newPrefix + key.dropFirst(legacyPrefix.count)
            // A value already written under the new name wins — it is newer
            // by construction (only post-rename builds write it).
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
            }
            defaults.removeObject(forKey: key)
        }
    }
}
