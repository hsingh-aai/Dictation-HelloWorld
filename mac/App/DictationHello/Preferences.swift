import DictationEngine
import Foundation
import Observation

/// UserDefaults-backed settings. Every key comes from `SettingKey`, so Reset sweeps them all.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var triggerKey: TriggerKey { didSet { defaults.set(triggerKey.rawValue, forKey: SettingKey.triggerKey.defaultsKey) } }
    var activationMode: ActivationMode { didSet { defaults.set(activationMode.rawValue, forKey: SettingKey.activationMode.defaultsKey) } }
    var soundPack: SoundPack { didSet { defaults.set(soundPack.rawValue, forKey: SettingKey.soundPack.defaultsKey) } }
    var keytermsText: String { didSet { defaults.set(keytermsText, forKey: SettingKey.keyterms.defaultsKey) } }
    /// Stored as a JSON string so it can be seeded with `defaults write`.
    var snippets: [Snippet] { didSet { defaults.set(Self.encode(snippets), forKey: SettingKey.snippets.defaultsKey) } }
    var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: SettingKey.inputDeviceUID.defaultsKey) } }
    var enhanced: Bool { didSet { defaults.set(enhanced, forKey: SettingKey.enhanced.defaultsKey) } }
    var profiles: [StyleProfile] { didSet { defaults.set(try? JSONEncoder().encode(profiles), forKey: SettingKey.styleProfiles.defaultsKey) } }
    /// nil = Default (the base instruction alone).
    var activeStyleID: UUID? { didSet { defaults.set(activeStyleID?.uuidString, forKey: SettingKey.activeStyle.defaultsKey) } }
    var developerMode: Bool { didSet { defaults.set(developerMode, forKey: SettingKey.developerMode.defaultsKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        triggerKey = TriggerKey(rawValue: defaults.integer(forKey: SettingKey.triggerKey.defaultsKey)) ?? .default
        activationMode = defaults.string(forKey: SettingKey.activationMode.defaultsKey).flatMap(ActivationMode.init) ?? .default
        soundPack = defaults.string(forKey: SettingKey.soundPack.defaultsKey).flatMap(SoundPack.init) ?? .default
        keytermsText = defaults.string(forKey: SettingKey.keyterms.defaultsKey) ?? ""
        snippets = Self.decodeSnippets(defaults.string(forKey: SettingKey.snippets.defaultsKey))
        inputDeviceUID = defaults.string(forKey: SettingKey.inputDeviceUID.defaultsKey)
        enhanced = defaults.object(forKey: SettingKey.enhanced.defaultsKey) as? Bool ?? true
        profiles = defaults.data(forKey: SettingKey.styleProfiles.defaultsKey)
            .flatMap { try? JSONDecoder().decode([StyleProfile].self, from: $0) } ?? []
        activeStyleID = defaults.string(forKey: SettingKey.activeStyle.defaultsKey).flatMap(UUID.init)
        developerMode = defaults.bool(forKey: SettingKey.developerMode.defaultsKey)
    }

    var activeProfile: StyleProfile? { profiles.first { $0.id == activeStyleID } }

    /// Styles as shown in the Output Style row: Default, then up to four profiles.
    var styleChoices: [(id: UUID?, name: String)] {
        [(nil, "Default")] + profiles.map { ($0.id, $0.name) }
    }

    private static func encode(_ snippets: [Snippet]) -> String? {
        (try? JSONEncoder().encode(snippets)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Accepts full records or just `{"trigger": …, "expansion": …}` pairs.
    private static func decodeSnippets(_ json: String?) -> [Snippet] {
        struct Loose: Decodable { var id: UUID?; var trigger: String; var expansion: String }
        guard let data = json?.data(using: .utf8), let loose = try? JSONDecoder().decode([Loose].self, from: data) else { return [] }
        return loose.map { Snippet(id: $0.id ?? UUID(), trigger: $0.trigger, expansion: $0.expansion) }
    }

    func removeAll() {
        for key in SettingKey.allCases { defaults.removeObject(forKey: key.defaultsKey) }
    }

    /// Read off the main actor by the mic factory and the dev log.
    nonisolated static func pinnedDeviceUID() -> String? {
        UserDefaults.standard.string(forKey: SettingKey.inputDeviceUID.defaultsKey)
    }

    nonisolated static func developerModeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: SettingKey.developerMode.defaultsKey)
    }
}
