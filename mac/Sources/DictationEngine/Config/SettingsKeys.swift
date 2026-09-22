import Foundation

/// The single roster of persisted settings. Adding a setting and adding it to the Reset sweep
/// are the same line.
public enum SettingKey: String, CaseIterable, Sendable {
    case triggerKey
    case activationMode
    case soundPack
    case keyterms
    case inputDeviceUID
    case enhanced
    case styleProfiles
    case activeStyle
    case developerMode
    case overlayOrigin
    case lastSignature

    public var defaultsKey: String { "dictation.\(rawValue)" }
}

public struct StyleProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Appended after the base instruction with the precedence preamble. Only the active one is sent.
    public var preferences: String

    public init(id: UUID = UUID(), name: String, preferences: String) {
        self.id = id
        self.name = name
        self.preferences = preferences
    }

    public static let maxCount = 4
}

public enum SoundPack: String, CaseIterable, Sendable, Identifiable {
    case glass, pop, off

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .glass: "Glass"
        case .pop: "Pop"
        case .off: "Off"
        }
    }

    /// System sound names for (start, stop).
    public var sounds: (start: String, stop: String)? {
        switch self {
        case .glass: ("Tink", "Glass")
        case .pop: ("Pop", "Bottle")
        case .off: nil
        }
    }

    public static let `default`: SoundPack = .glass
}

/// Setup readiness: permissions + key only. **Not** the trigger key, which has a default, so a
/// shortcut change can't trap the user in the wizard.
public struct SetupReadiness: Sendable, Equatable {
    public var microphone: Bool
    public var accessibility: Bool
    public var apiKey: Bool

    public init(microphone: Bool, accessibility: Bool, apiKey: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.apiKey = apiKey
    }

    public var isReady: Bool { microphone && accessibility && apiKey }
}
