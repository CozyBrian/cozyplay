import Foundation
import IOKit

/// Stable per-machine identity, so a laptop keeps its speaker identity
/// (name, volume, latency trim) across reconnects and app restarts.
enum HostIdentity {
    /// A stable per-machine id derived from the hardware UUID when available.
    static func stableID() -> String {
        if let uuid = hardwareUUID() { return "cozyplay-\(uuid)" }
        return "cozyplay-\(Host.current().localizedName ?? UUID().uuidString)"
    }

    private static func hardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }
        guard let cf = IORegistryEntryCreateCFProperty(
            platformExpert, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return nil }
        return cf
    }
}
