import DictationEngine
import Foundation

/// Dev and shipping builds get their own bundle id, display name and Keychain item, so they are
/// two Privacy rows granted independently. The id is always all-lowercase: TCC records the
/// Accessibility client in lowercase, and a mixed-case id never matches its own record.
enum AppIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.example.dictationhello.dev"
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Dictation Hello"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    static let userAgentName = "DictationHello"
    static var keychain: KeychainStore { KeychainStore(service: bundleID) }
}
