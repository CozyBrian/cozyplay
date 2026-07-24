import Foundation

/// App-level settings, backed by UserDefaults. Views bind via @AppStorage with
/// these keys; controllers read through the typed accessors so both sides stay
/// on the same values.
enum AppSettings {
    static let defaultBufferMsKey = "cozyplay.defaultBufferMs"
    static let displayNameOverrideKey = "cozyplay.displayNameOverride"
    static let defaultPartyNameKey = "cozyplay.defaultPartyName"
    static let showDiagnosticsKey = "cozyplay.showDiagnostics"
    static let keepSourceAudibleKey = "cozyplay.keepSourceAudible"

    /// End-to-end playback delay a new party starts with.
    static var defaultBufferMs: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: defaultBufferMsKey)
            guard stored != 0 else { return EngineConstants.defaultBufferMs }
            return max(EngineConstants.minBufferMs, min(EngineConstants.maxBufferMs, stored))
        }
        set {
            UserDefaults.standard.set(
                max(EngineConstants.minBufferMs, min(EngineConstants.maxBufferMs, newValue)),
                forKey: defaultBufferMsKey
            )
        }
    }

    /// How this Mac introduces itself to a party ("" = use the computer name).
    /// A per-speaker rename made by the host (persisted by hostID) wins over this.
    static var displayNameOverride: String {
        get { UserDefaults.standard.string(forKey: displayNameOverrideKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: displayNameOverrideKey) }
    }

    static var showDiagnostics: Bool {
        get { UserDefaults.standard.bool(forKey: showDiagnosticsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showDiagnosticsKey) }
    }

    /// Troubleshooting: leave the tapped apps audible on the host instead of
    /// muting them in favor of the delayed, synced self-playback.
    static var keepSourceAudible: Bool {
        get { UserDefaults.standard.bool(forKey: keepSourceAudibleKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepSourceAudibleKey) }
    }

    /// Preferred party name when hosting ("" = derive from the device name).
    static var defaultPartyName: String {
        get { UserDefaults.standard.string(forKey: defaultPartyNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: defaultPartyNameKey) }
    }

    /// The name this Mac uses in parties.
    static func deviceName() -> String {
        let override = displayNameOverride.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override }
        return Host.current().localizedName ?? "MacBook"
    }

    /// The party name this Mac hosts with.
    static func partyName() -> String {
        let stored = defaultPartyName.trimmingCharacters(in: .whitespaces)
        if !stored.isEmpty { return stored }
        return "\(deviceName())’s party"
    }
}
