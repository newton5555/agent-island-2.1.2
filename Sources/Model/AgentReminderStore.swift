import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AgentReminderStore: ObservableObject {
    static let shared = AgentReminderStore()

    enum AlarmSoundPreset: String, CaseIterable, Hashable {
        case basso = "Basso"
        case blow = "Blow"
        case bottle = "Bottle"
        case frog = "Frog"
        case funk = "Funk"
        case glass = "Glass"
        case hero = "Hero"
        case morse = "Morse"
        case ping = "Ping"
        case pop = "Pop"
        case purr = "Purr"
        case sosumi = "Sosumi"
        case submarine = "Submarine"
        case tink = "Tink"

        var soundName: NSSound.Name { NSSound.Name(rawValue) }
        var label: String { rawValue }
    }

    /// Apple's own ringtone library — the "苹果闹钟" sound the owner asked
    /// the alarm to match (2026-08-09). Every Mac ships these inside
    /// ToneLibrary.framework for FaceTime; they are referenced in place at
    /// runtime and never bundled — they are Apple's audio, and they are
    /// already on the disk. If a future macOS moves the directory the tier
    /// simply disappears from the picker and the classic presets remain.
    enum AppleRingtones {
        static let directory =
            "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones"

        /// Curated alarm-grade picks, Radar first — the iPhone default
        /// alarm. The library holds 78 tones; a full dump would bury the
        /// picker, so this is the set that actually reads as an alarm.
        static let curated = [
            "Radar", "Alarm", "Apex", "Beacon", "Chimes", "Signal",
            "Circuit", "Sencha", "Slow Rise", "Stargaze", "Reflection", "Waves",
        ]

        static let available: [String] = curated.filter {
            FileManager.default.fileExists(atPath: url(for: $0).path)
        }

        static func url(for name: String) -> URL {
            URL(fileURLWithPath: directory).appendingPathComponent(name + ".m4r")
        }
    }

    enum AlarmSoundChoice: Hashable {
        case ringtone(String)
        case preset(AlarmSoundPreset)
        case custom

        static var all: [AlarmSoundChoice] {
            AppleRingtones.available.map { .ringtone($0) }
                + AlarmSoundPreset.allCases.map { .preset($0) }
                + [.custom]
        }

        var storageValue: String {
            switch self {
            case .ringtone(let name): return "Ringtone:" + name
            case .preset(let preset): return preset.rawValue
            case .custom: return "Custom"
            }
        }

        var label: String {
            switch self {
            case .ringtone(let name): return name
            case .preset(let preset): return preset.label
            case .custom: return "Custom sound"
            }
        }

        init?(storageValue: String) {
            if storageValue == "Custom" {
                self = .custom
            } else if storageValue.hasPrefix("Ringtone:") {
                let name = String(storageValue.dropFirst("Ringtone:".count))
                // A tone this system doesn't have (synced defaults, OS
                // change) must not resolve — the caller falls back to the
                // default rather than a silent alarm.
                guard FileManager.default.fileExists(atPath: AppleRingtones.url(for: name).path) else {
                    return nil
                }
                self = .ringtone(name)
            } else if let preset = AlarmSoundPreset(rawValue: storageValue) {
                self = .preset(preset)
            } else {
                return nil
            }
        }
    }

    private static let enabledKey = "AgentIsland.agentReminders"
    private static let soundEnabledKey = "AgentIsland.agentReminderSound"
    private static let volumeKey = "AgentIsland.agentReminderVolume"
    private static let soundPresetKey = "AgentIsland.agentReminderSoundPreset"
    private static let soundChoiceKey = "AgentIsland.agentReminderSoundChoice"
    private static let customSoundPathKey = "AgentIsland.agentReminderCustomSoundPath"
    private static let showSessionDetailsKey = "AgentIsland.agentReminderShowSessionDetails"
    private static let frontmostSoundOnlyKey = "AgentIsland.agentReminderFrontmostSoundOnly"
    private static let alarmWhenFrontmostKey = "AgentIsland.agentReminderAlarmWhenFrontmost"
    private var previewSound: NSSound?
    /// Retains the in-flight #9 chime — NSSound stops when released.
    private var frontmostChime: NSSound?

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: Self.soundEnabledKey) }
    }

    @Published var volume: Double {
        didSet {
            let clamped = min(1, max(0, volume))
            UserDefaults.standard.set(clamped, forKey: Self.volumeKey)
        }
    }

    @Published var soundPreset: AlarmSoundPreset {
        didSet { UserDefaults.standard.set(soundPreset.rawValue, forKey: Self.soundPresetKey) }
    }

    @Published var soundChoice: AlarmSoundChoice {
        didSet { UserDefaults.standard.set(soundChoice.storageValue, forKey: Self.soundChoiceKey) }
    }

    @Published var customSoundPath: String? {
        didSet {
            if let customSoundPath, !customSoundPath.isEmpty {
                UserDefaults.standard.set(customSoundPath, forKey: Self.customSoundPathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.customSoundPathKey)
            }
        }
    }

    @Published var showSessionDetails: Bool {
        didSet { UserDefaults.standard.set(showSessionDetails, forKey: Self.showSessionDetailsKey) }
    }

    /// #9: a turn that finishes while its host app is frontmost is
    /// baselined (seen, no popup) — but "the app is frontmost" doesn't
    /// always mean "the user noticed". Opt-in: play one chime at that
    /// moment instead of total silence. Default off preserves the
    /// existing fully-silent behavior.
    @Published var frontmostSoundOnly: Bool {
        didSet { UserDefaults.standard.set(frontmostSoundOnly, forKey: Self.frontmostSoundOnlyKey) }
    }

    /// Whether a finished turn still raises its alarm while the session's own
    /// app is frontmost. Off by default: watching the turn finish IS the
    /// notification, and a popup over the window you are already reading was
    /// the original complaint (#30). Some people want it anyway — a long turn
    /// in a background pane of the same app is easy to miss — so it is a
    /// switch rather than a rule (owner call, 2026-08-08).
    @Published var alarmWhenFrontmost: Bool {
        didSet { UserDefaults.standard.set(alarmWhenFrontmost, forKey: Self.alarmWhenFrontmostKey) }
    }

    private init() {
        alarmWhenFrontmost = UserDefaults.standard.bool(forKey: Self.alarmWhenFrontmostKey)
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.enabledKey)
        soundEnabled = UserDefaults.standard.object(forKey: Self.soundEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.soundEnabledKey)
        volume = UserDefaults.standard.object(forKey: Self.volumeKey) == nil
            ? 0.8
            : min(1, max(0, UserDefaults.standard.double(forKey: Self.volumeKey)))
        let preset = UserDefaults.standard.string(forKey: Self.soundPresetKey)
        let initialPreset = preset.flatMap(AlarmSoundPreset.init(rawValue:)) ?? .glass
        soundPreset = initialPreset
        let storedCustomSoundPath = UserDefaults.standard.string(forKey: Self.customSoundPathKey)
        customSoundPath = storedCustomSoundPath
        let storedChoice = UserDefaults.standard.string(forKey: Self.soundChoiceKey)
            .flatMap(AlarmSoundChoice.init(storageValue:))
        if let storedChoice, storedChoice != .custom || storedCustomSoundPath != nil {
            soundChoice = storedChoice
        } else if storedCustomSoundPath != nil {
            soundChoice = .custom
        } else if let ringtone = AppleRingtones.available.first {
            // Radar, the iPhone default alarm — the owner wants the alarm
            // to sound like Apple's, and this is the one everyone knows.
            soundChoice = .ringtone(ringtone)
        } else {
            soundChoice = .preset(initialPreset)
        }
        showSessionDetails = UserDefaults.standard.bool(forKey: Self.showSessionDetailsKey)
        frontmostSoundOnly = UserDefaults.standard.bool(forKey: Self.frontmostSoundOnlyKey)
    }

    var soundLabel: String {
        switch soundChoice {
        case .ringtone(let name):
            return name
        case .preset(let preset):
            return L10n.tr(preset.label)
        case .custom:
            guard let customSoundPath, !customSoundPath.isEmpty else {
                return L10n.tr("Custom sound")
            }
            return (customSoundPath as NSString).lastPathComponent
        }
    }

    func selectPreset(_ preset: AlarmSoundPreset) {
        soundPreset = preset
        soundChoice = .preset(preset)
    }

    func selectSoundChoice(_ choice: AlarmSoundChoice) {
        switch choice {
        case .ringtone:
            soundChoice = choice
            previewSoundChoice(choice)
        case .preset(let preset):
            selectPreset(preset)
            previewSoundChoice(.preset(preset))
        case .custom:
            guard customSoundPath != nil, soundChoice != .custom else {
                chooseCustomSound()
                return
            }
            soundChoice = .custom
            previewSoundChoice(.custom)
        }
    }

    func chooseCustomSound() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.customSoundPath = url.path
                self?.soundChoice = .custom
                self?.previewSoundChoice(.custom)
            }
        }
    }

    func previewSoundChoice(_ choice: AlarmSoundChoice) {
        guard soundEnabled, let sound = makeSound(for: choice) else { return }
        previewSound?.stop()
        sound.volume = Float(volume)
        previewSound = sound
        sound.play()
    }

    func makeAlarmSound() -> NSSound? {
        makeSound(for: soundChoice)
            ?? makeSound(for: .preset(soundPreset))
            ?? NSSound(named: NSSound.Name("Glass"))
    }

    /// The #9 chime: the turn alarm's exact sound and volume, played once
    /// (never looped) and honoring the global sound toggle.
    func playFrontmostChime() {
        guard soundEnabled, let sound = makeAlarmSound() else { return }
        frontmostChime?.stop()
        sound.volume = Float(volume)
        frontmostChime = sound
        sound.play()
    }

    private func makeSound(for choice: AlarmSoundChoice) -> NSSound? {
        switch choice {
        case .ringtone(let name):
            let url = AppleRingtones.url(for: name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return NSSound(contentsOf: url, byReference: true)
        case .preset(let preset):
            return NSSound(named: preset.soundName)
        case .custom:
            guard let path = customSoundPath,
                  FileManager.default.fileExists(atPath: path)
            else { return nil }
            return NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true)
        }
    }
}
